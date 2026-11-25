;;; jchh-dev-env.el --- helm-make / projectile / worktree glue for the dev-env layout  -*- lexical-binding: t; -*-

;; Companion to the dev-env repository this file lives in (see its README, section "Emacs").
;;
;; What it does, all opt-in through `jchh-dev-env-enable':
;;
;;  * Build dir per worktree, persistent: the chosen build dir is written as
;;    `helm-make-build-dir' (relative, e.g. "build/DEBUG") into the worktree's
;;    .dir-locals.el.  Every buffer under that worktree gets it buffer-locally, so
;;    `SPC c c' (helm-make-projectile) builds the right tree for the current file,
;;    and it survives restarts.
;;  * Build environment per build dir, not global: if <build-dir>/.env exists (the
;;    yocto preset writes it at configure time) its KEY=VALUE lines are passed to that
;;    compile process only, through `compilation-environment'.  No `setenv'.
;;  * One compilation buffer per project so `recompile' (SPC c r) reruns the current
;;    file's project, not whatever was built last.
;;  * Thin wrappers around the `wt' CLI: switch / add / review / remove worktrees.
;;    After switching, `jchh-dev-env-switch-action' runs (default: magit-status).
;;  * `jchh-dev-env-configure': run `cmake --preset <p>' in the current worktree, the
;;    yocto preset through the `sdk' shell helper, and adopt the resulting build dir.
;;
;; Nothing here runs at load time except defining functions and variables.
;; `jchh-dev-env-disable' reverts every global change `jchh-dev-env-enable' made.
;;
;; Spacemacs wiring (in your layer's init function, after `use-package'):
;;
;;   (use-package jchh-dev-env
;;     :load-path "<dev-env>/emacs"
;;     :config (jchh-dev-env-enable))
;;   (spacemacs/declare-prefix "cW" "worktrees")
;;   (spacemacs/set-leader-keys
;;     "cS"  'jchh-dev-env-select-build-dir
;;     "cWs" 'jchh-dev-env-select-build-dir
;;     "cWr" 'jchh-dev-env-rebuild
;;     "cWw" 'jchh-wt-switch
;;     "cWa" 'jchh-wt-add
;;     "cWp" 'jchh-wt-review
;;     "cWk" 'jchh-wt-remove
;;     "cWc" 'jchh-dev-env-configure)

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'compile)
(declare-function projectile-project-root "projectile")
(declare-function projectile-project-buffers "projectile")
(declare-function projectile-switch-project-by-name "projectile")
(declare-function projectile-add-known-project "projectile")
(declare-function projectile-compilation-buffer-name "projectile")
(declare-function projectile-current-project-buffer-p "projectile")
(declare-function magit-status "magit")
(defvar helm-make-build-dir)
(defvar projectile-switch-project-action)

(defgroup jchh-dev-env nil "dev-env integration." :group 'tools)

(defcustom jchh-dev-env-dir
  (file-name-directory
   (directory-file-name
    (file-name-directory (file-truename (or load-file-name buffer-file-name default-directory)))))
  "The dev-env repository (for bin/wt, shell/env.sh and the sdk helper).
Default: the directory above the one this file was loaded from."
  :type 'directory)

(defcustom jchh-dev-env-wt-program (expand-file-name "bin/wt" jchh-dev-env-dir)
  "Absolute path of the wt script (no dependency on exec-path)."
  :type 'file)

(defun jchh-dev-env--setting (name default)
  "Value of the dev-env layout setting NAME (shell/config.sh, local config), or DEFAULT."
  (let ((v (ignore-errors
             (string-trim
              (shell-command-to-string
               (format "bash -c '. %s && printf %%s \"$%s\"'"
                       (shell-quote-argument (expand-file-name "shell/config.sh" jchh-dev-env-dir))
                       name))))))
    (if (and v (not (string-empty-p v))) v default)))

(defcustom jchh-dev-env-sdk-root
  (jchh-dev-env--setting "DEV_ENV_SDK_ROOT" (expand-file-name "~/.config/dev-env/sdks"))
  "Directory of the Yocto SDKs `sdk' knows, one entry each (see `sdk add' in shell/env.sh)."
  :type 'directory)

(defcustom jchh-dev-env-switch-action #'magit-status
  "Function run in the worktree root after `jchh-wt-*' switched projectile to it.
projectile's own default would be `projectile-find-file', which prompts for a file."
  :type 'function)

(defcustom jchh-dev-env-containers
  (let ((base (jchh-dev-env--setting "DEV_ENV_BASE_DIR" (expand-file-name "~/development"))))
    (when (file-directory-p base)
      (cl-remove-if-not (lambda (d) (file-directory-p (expand-file-name ".bare" d)))
                        (directory-files base t "\\`[^.]"))))
  "Worktree containers offered by `jchh-wt-switch' in addition to the current one.
Default: every directory below DEV_ENV_BASE_DIR that has a .bare repository (at load time)."
  :type '(repeat directory))

(defcustom jchh-dev-env-default-build-dir "build/DEBUG"
  "Build dir used when a worktree has no .dir-locals.el yet."
  :type 'string)

(defconst jchh-dev-env--dir-locals-marker
  ";;; Directory Local Variables -- managed by dev-env (wt setup / jchh-dev-env-select-build-dir)")

;;;; helpers

(defun jchh-dev-env--root ()
  "Project root of the current buffer, with trailing slash, or signal."
  (require 'projectile)
  (or (projectile-project-root) (user-error "Not inside a projectile project")))

(defun jchh-dev-env--build-dir (&optional root)
  "Absolute build dir for ROOT (default: current project) from `helm-make-build-dir'."
  (let ((root (or root (jchh-dev-env--root)))
        (rel (if (and (boundp 'helm-make-build-dir) (stringp helm-make-build-dir)
                      (not (string-empty-p helm-make-build-dir)))
                 helm-make-build-dir
               jchh-dev-env-default-build-dir)))
    (file-name-as-directory (expand-file-name rel root))))

(defun jchh-dev-env--build-dir-candidates (root)
  "Immediate subdirectories of ROOT/build that contain a Makefile, as \"build/NAME\"."
  (let ((build (expand-file-name "build" root)))
    (when (file-directory-p build)
      (cl-loop for d in (directory-files build nil "\\`[^.]")
               when (file-exists-p (expand-file-name "Makefile" (expand-file-name d build)))
               collect (concat "build/" d)))))

(defun jchh-dev-env--read-env-file (file)
  "Return the KEY=VALUE lines of FILE as a list of strings, ignoring comments and blanks."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (cl-loop for line in (split-string (buffer-string) "\n" t)
               for l = (string-trim line)
               when (and (not (string-prefix-p "#" l)) (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*=" l))
               collect l))))

;;;; .dir-locals.el handling

(defun jchh-dev-env--read-dir-locals (file)
  "Read the alist in FILE, or nil.  Refuses (returns `foreign') a file not managed by dev-env."
  (cond
   ((not (file-exists-p file)) nil)
   ((not (with-temp-buffer (insert-file-contents file)
                           (search-forward "managed by dev-env" nil t)))
    'foreign)
   (t (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case nil (read (current-buffer)) (error nil))))))

(defun jchh-dev-env--write-build-dir (root rel)
  "Store REL as `helm-make-build-dir' in ROOT/.dir-locals.el and re-apply it to open buffers."
  (let* ((file (expand-file-name ".dir-locals.el" root))
         (alist (jchh-dev-env--read-dir-locals file)))
    (when (eq alist 'foreign)
      (user-error "%s is not managed by dev-env; edit it yourself (helm-make-build-dir . \"%s\")" file rel))
    (let* ((nil-entry (or (assq nil alist) (cons nil nil)))
           (vars (assq-delete-all 'helm-make-build-dir (copy-sequence (cdr nil-entry))))
           (new-nil (cons nil (cons (cons 'helm-make-build-dir rel) vars)))
           (rest (cl-remove-if (lambda (e) (null (car e))) alist)))
      (with-temp-file file
        (insert jchh-dev-env--dir-locals-marker "\n")
        (pp (cons new-nil rest) (current-buffer))))
    ;; forget the cached copy and re-apply to every buffer of this project
    (setq dir-locals-directory-cache
          (cl-remove-if (lambda (e) (file-equal-p (car e) root)) dir-locals-directory-cache))
    (dolist (b (projectile-project-buffers))
      (with-current-buffer b
        (when buffer-file-name
          (hack-dir-local-variables)
          (hack-local-variables-apply))))))

;;;; commands: build dir, rebuild

;;;###autoload
(defun jchh-dev-env-select-build-dir ()
  "Pick ROOT/build/<NAME> for the current project and remember it in .dir-locals.el.
Also points ROOT/compile_commands.json at that build dir.  Replaces the old
`jchh-helm-make-select-build-dir'; if `jchh-load-env' from the old package is
loaded it is still called, so root-level .env files keep working."
  (interactive)
  (let* ((root (jchh-dev-env--root))
         (cands (or (jchh-dev-env--build-dir-candidates root)
                    (user-error "No build/*/Makefile under %s; run cmake --preset first" root)))
         (rel (completing-read "Build directory: " cands nil t nil nil
                               (car (member (and (boundp 'helm-make-build-dir) helm-make-build-dir) cands)))))
    (jchh-dev-env--adopt-build-dir root rel)))

(defun jchh-dev-env--adopt-build-dir (root rel)
  "Make REL (e.g. \"build/DEBUG\") the build dir of ROOT: dir-locals, symlink, message."
  (jchh-dev-env--write-build-dir root rel)
  (let ((link (expand-file-name "compile_commands.json" root)))
    (when (or (file-symlink-p link) (not (file-exists-p link)))
      (make-symbolic-link (concat rel "/compile_commands.json") link t)))
  (when (fboundp 'jchh-load-env) (jchh-load-env root))
  (message "helm-make-build-dir = %s for %s%s" rel (abbreviate-file-name root)
           (if (file-exists-p (expand-file-name ".env" (expand-file-name rel root)))
               " (SDK environment from .env will be applied to compiles)" "")))

;;;; configure

(defun jchh-dev-env--presets (root)
  "Configure presets visible in ROOT, from `cmake --list-presets'."
  (let ((default-directory root))
    (with-temp-buffer
      (process-file "cmake" nil t nil "--list-presets")
      (goto-char (point-min))
      (cl-loop while (re-search-forward "^  \"\\([^\"]+\\)\"" nil t)
               collect (match-string 1)))))

(defun jchh-dev-env--sdks ()
  "SDK names under `jchh-dev-env-sdk-root' that have an environment-setup script."
  (when (file-directory-p jchh-dev-env-sdk-root)
    (cl-remove-if-not
     (lambda (n)
       (let ((d (expand-file-name n jchh-dev-env-sdk-root)))
         (and (file-directory-p d) (directory-files d nil "\\`environment-setup-"))))
     (directory-files jchh-dev-env-sdk-root nil "\\`[^.]"))))

;;;###autoload
(defun jchh-dev-env-configure ()
  "Run cmake --preset in the current worktree and adopt the resulting build dir.
Native presets come from CMakeUserPresets.json; \"yocto <sdk>\" entries run the
configure through the dev-env `sdk' shell helper so the SDK environment is right."
  (interactive)
  (let* ((root (jchh-dev-env--root))
         (cands (append (jchh-dev-env--presets root)
                        (mapcar (lambda (sdk) (concat "yocto " sdk)) (jchh-dev-env--sdks))))
         (choice (completing-read "Configure preset: "
                                  (or cands (user-error "No presets in %s; is CMakeUserPresets.json there? (wt setup)" root))
                                  nil t))
         (cmd (if (string-prefix-p "yocto " choice)
                  (format "bash -c 'source %s && sdk %s && cmake --preset yocto'"
                          (shell-quote-argument (expand-file-name "shell/env.sh" jchh-dev-env-dir))
                          (shell-quote-argument (substring choice 6)))
                (format "cmake --preset %s" (shell-quote-argument choice))))
         (default-directory root)
         (buf (compile cmd)))
    (with-current-buffer buf
      (add-hook 'compilation-finish-functions
                (lambda (b status)
                  (when (string-prefix-p "finished" status)
                    (with-current-buffer b
                      (save-excursion
                        (goto-char (point-min))
                        (when (re-search-forward "^-- Build files have been written to: \\(.*\\)$" nil t)
                          (jchh-dev-env--adopt-build-dir
                           root (file-relative-name (match-string 1) root)))))))
                nil t))))

;;;###autoload
(defun jchh-dev-env-rebuild ()
  "Run make (default target) in the current project's build dir.
Needs no memory of a previous compile, so it works right after a restart."
  (interactive)
  (let* ((dir (jchh-dev-env--build-dir))
         (default-directory dir))
    (unless (file-exists-p (expand-file-name "Makefile" dir))
      (user-error "No Makefile in %s; run cmake --preset first" dir))
    (compile (format "make -j%d" (num-processors)))))

;;;; per-build-dir environment

(defun jchh-dev-env--compilation-start-advice (orig &rest args)
  "Pass <default-directory>/.env to the compile process, if present.
helm-make and `jchh-dev-env-rebuild' start compiles with `default-directory' set to
the build dir; `recompile' restores it.  Native build dirs have no .env."
  (let* ((env (jchh-dev-env--read-env-file (expand-file-name ".env" default-directory)))
         (compilation-environment (append env compilation-environment)))
    (when env (message "dev-env: applying %d SDK variables from %s.env" (length env)
                       (abbreviate-file-name default-directory)))
    (apply orig args)))

;;;; worktrees via wt

(defun jchh-wt--run (dir &rest args)
  "Run wt ARGS in DIR synchronously; return trimmed stdout or signal with stderr."
  (let ((default-directory (file-name-as-directory (expand-file-name dir))))
    (with-temp-buffer
      (let ((rc (apply #'process-file jchh-dev-env-wt-program nil (current-buffer) nil args)))
        (unless (zerop rc)
          (user-error "wt %s failed: %s" (string-join args " ") (string-trim (buffer-string))))
        (string-trim (buffer-string))))))

(defun jchh-wt--container (&optional dir)
  "Container of DIR (default: current project), or nil when not inside one."
  (condition-case nil
      (jchh-wt--run (or dir (ignore-errors (jchh-dev-env--root)) default-directory) "root")
    (user-error nil)))

(defun jchh-wt--worktrees (container)
  "Worktree paths of CONTAINER, without the bare repo."
  (cl-loop for line in (split-string
                        (with-temp-buffer
                          (let ((default-directory (file-name-as-directory container)))
                            (process-file "git" nil t nil "worktree" "list" "--porcelain"))
                          (buffer-string))
                        "\n" t)
           when (and (string-prefix-p "worktree " line) (not (string-suffix-p "/.bare" line)))
           collect (file-name-as-directory (substring line 9))))

(defun jchh-wt--all-worktrees ()
  (delete-dups
   (cl-loop for c in (delq nil (cons (jchh-wt--container) (mapcar #'expand-file-name jchh-dev-env-containers)))
            when (file-directory-p (expand-file-name ".bare" c))
            append (jchh-wt--worktrees c))))

(defun jchh-wt--visit (path)
  "Make PATH a known projectile project, switch to it, run `jchh-dev-env-switch-action'."
  (require 'projectile)
  (projectile-add-known-project path)
  (let ((projectile-switch-project-action jchh-dev-env-switch-action))
    (projectile-switch-project-by-name path)))

(defun jchh-wt--run-async (container &rest args)
  "Run wt ARGS in CONTAINER in a compilation buffer, then visit the new worktree."
  (let* ((default-directory (file-name-as-directory container))
         (buf (compile (mapconcat #'shell-quote-argument (cons jchh-dev-env-wt-program args) " "))))
    (with-current-buffer buf
      (add-hook 'compilation-finish-functions
                (lambda (_b status)
                  (when (string-prefix-p "finished" status)
                    (let ((path (save-excursion
                                  (goto-char (point-min))
                                  (when (re-search-forward "^wt: \\(?:worktree ready\\|review worktree ready\\|updated\\): \\(/.*?\\)\\(?: to.*\\)?$" nil t)
                                    (match-string 1)))))
                      (when path (jchh-wt--visit path)))))
                nil t))))

;;;###autoload
(defun jchh-wt-switch ()
  "Choose a worktree from the known containers and switch projectile to it."
  (interactive)
  (let ((wts (or (jchh-wt--all-worktrees) (user-error "No worktrees found; check jchh-dev-env-containers"))))
    (jchh-wt--visit (completing-read "Worktree: " (mapcar #'abbreviate-file-name wts) nil t))))

;;;###autoload
(defun jchh-wt-add (name)
  "wt add NAME in the current container, then switch to the new worktree."
  (interactive "sBranch / worktree name: ")
  (jchh-wt--run-async (or (jchh-wt--container) (user-error "Not inside a worktree container")) "add" name))

;;;###autoload
(defun jchh-wt-review (pr)
  "wt review PR in the current container, then switch to the review worktree."
  (interactive "nPR number: ")
  (jchh-wt--run-async (or (jchh-wt--container) (user-error "Not inside a worktree container"))
                      "review" (number-to-string pr)))

;;;###autoload
(defun jchh-wt-remove ()
  "wt rm a worktree of the current container (asks; never forces)."
  (interactive)
  (let* ((c (or (jchh-wt--container) (user-error "Not inside a worktree container")))
         (wts (cl-remove-if (lambda (p) (string= (file-name-nondirectory (directory-file-name p)) "main"))
                            (jchh-wt--worktrees c)))
         (path (completing-read "Remove worktree: " (mapcar #'abbreviate-file-name wts) nil t))
         (name (file-relative-name (expand-file-name path) c)))
    (when (yes-or-no-p (format "Remove worktree %s (branch is kept)? " name))
      (message "%s" (jchh-wt--run c "rm" name)))))

;;;; enable / disable

(defvar jchh-dev-env--saved nil "Global values replaced by `jchh-dev-env-enable'.")

;;;###autoload
(defun jchh-dev-env-enable ()
  "Install the advice and the per-project compilation settings."
  (interactive)
  (require 'projectile)
  (put 'helm-make-build-dir 'safe-local-variable #'stringp)
  (unless jchh-dev-env--saved
    (setq jchh-dev-env--saved
          (list compilation-buffer-name-function compilation-save-buffers-predicate)))
  (setq compilation-buffer-name-function #'projectile-compilation-buffer-name
        compilation-save-buffers-predicate #'projectile-current-project-buffer-p)
  (advice-add 'compilation-start :around #'jchh-dev-env--compilation-start-advice)
  (message "jchh-dev-env enabled"))

;;;###autoload
(defun jchh-dev-env-disable ()
  "Undo `jchh-dev-env-enable'.  .dir-locals.el files stay (they are plain data)."
  (interactive)
  (advice-remove 'compilation-start #'jchh-dev-env--compilation-start-advice)
  (when jchh-dev-env--saved
    (setq compilation-buffer-name-function (nth 0 jchh-dev-env--saved)
          compilation-save-buffers-predicate (nth 1 jchh-dev-env--saved)
          jchh-dev-env--saved nil))
  (message "jchh-dev-env disabled"))

(provide 'jchh-dev-env)
;;; jchh-dev-env.el ends here
