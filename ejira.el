;;; ejira.el --- org-mode interface to JIRA

;; Copyright (C) 2017 - 2019 Henrik Nyman

;; This file is NOT part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; TODO:
;; - Sprint handling
;; - Attachments

;;; Code:

(require 'org)
(require 'dash-functional)
(require 'ejira-core)



(defvar ejira-push-deadline-changes t
  "Sync deadlines to server when updated with `ejira-set-deadline'.")

(defun ejira-add-comment (to-clocked)
  "Capture new comment to issue under point.
With prefix-argument TO-CLOCKED add comment to currently clocked issue."
  (interactive "P")
  (ejira--capture-comment (if to-clocked
                              (ejira--get-clocked-issue)
                            (ejira-issue-id-under-point))))

(defun ejira-delete-comment ()
  "Delete comment under point."
  (interactive)
  (let* ((item (ejira-get-id-under-point "ejira-comment"))
         (id (nth 1 item)))
    (when (y-or-n-p (format "Delete comment %s? " (cdr id)))
      (ejira--delete-comment (car id) (cdr id)))))

(defun ejira-pull-item-under-point ()
  "Update the issue, project or comment under point."
  (interactive)
  (let* ((item (ejira-get-id-under-point))
         (id (nth 1 item))
         (type (nth 0 item)))
    (cond ((equal type "ejira-comment")
           (ejira--update-comment
            (car id) (ejira--parse-comment (jiralib2-get-comment (car id) (cdr id)))))
          ((equal type "ejira-project")
           (ejira--update-project id))
          (t
           (ejira--update-task id)))))

(defun ejira-push-item-under-point ()
  "Upload content of issue, project or comment under point to server.
For a project, this includes the summary, for a task the summary and
description, and for the comment the body."
  (interactive)
  (let* ((item (ejira-get-id-under-point))
         (id (nth 1 item))
         (type (nth 0 item)))
    (cond ((equal type "ejira-comment")
           (jiralib2-edit-comment
            (car id) (cdr id)
            (ejira-parser-org-to-jira
             (ejira--get-heading-body
              (nth 2 item)))))
          ((equal type "ejira-project")
           (message "TODO"))
          (t
           (jiralib2-update-summary-description
            id
            (ejira--with-point-on id
              (ejira--strip-properties (org-get-heading t t t t)))
            (ejira-parser-org-to-jira
             (ejira--get-heading-body
              (ejira--find-task-subheading id ejira-description-heading-name))))))))

(defun ejira-create-item-under-point ()
  "Create issue based on complete ejira-issue sans ID."
  (interactive)
  (let* ((item (ejira-get-id-under-point))
         (assignee "Unassigned")
         (summary (ejira--with-point-on (nth 1 item) (ejira--strip-properties (org-get-heading t t t t))))
         (properties (save-excursion
                       (goto-char (nth 2 item))
                       (org-entry-properties)))
         (issuetype (cdr (assoc "ISSUETYPE" properties)))
         (type (cdr (assoc "TYPE" properties)))
         (project (cdr (assoc "CATEGORY" properties)))
         (description (ejira-parser-org-to-jira
                       (ejira--get-heading-body
                        (ejira--find-task-subheading (nth 1 item) ejira-description-heading-name))))
         (response (cond ((string= type "ejira-epic")
                          (jiralib2-create-issue
                           project
                           issuetype
                           summary
                           description
                           `(assignee . ,assignee)
                           `(customfield_10011 . ,summary))) ; Epic Name
                         (t
                          (jiralib2-create-issue
                           project
                           issuetype
                           summary
                           description
                           `(assignee . ,assignee))))))
    (org-entry-put nil "ID" (cdr (assoc 'key response)))
    (org-entry-put nil "URL" (cdr (assoc 'self response)))))



(defun ejira--heading-to-item (heading project-id type exclude-subheadings &rest args)
  "Create an item from HEADING of TYPE into PROJECT-ID with parameters ARGS."
  (let* ((summary (ejira--strip-properties (org-get-heading t t t t)))
         (description (ejira-parser-org-to-jira (ejira--get-heading-body heading exclude-subheadings)))
         (item (ejira--parse-item
                (apply #'jiralib2-create-issue project-id
                       type summary description args))))

    (ejira--update-task (ejira-task-key item))
    (ejira-task-key item)))

(defun ejira-heading-to-task (focus)
  "Make the current org-heading into a JIRA task.
With prefix argument FOCUS, focus the issue after creating."
  (interactive "P")
  (let* ((heading (save-excursion
                    (if (outline-on-heading-p t)
                        (beginning-of-line)
                      (outline-back-to-heading))
                    (point-marker)))
         (project-id (ejira--select-project))
         (key (when project-id (ejira--heading-to-item heading project-id "Task" nil))))

    (when (and key focus)
      (ejira-focus-on-issue key))))

(defun ejira-heading-to-story-with-subtasks (focus)
  "Make the current org-heading into a JIRA story.
Subheadings will be treated as sub-tasks.
With prefix argument FOCUS, focus the issue after creating."
  (interactive "P")
  (outline-back-to-heading)
  (let* ((level (outline-level))
         (project-id (ejira--select-project))
         (story (ejira--heading-to-item (point-marker) project-id ejira-story-type-name t)))
    (outline-next-heading)
    (when (< level (outline-level))
      (condition-case nil
          (while
              (progn
                (ejira--heading-to-item (point-marker)
                                        project-id
                                        ejira-subtask-type-name
                                        nil
                                        `(parent . ((key . ,story))))
                (outline-forward-same-level 1)
                t))
        (error (message "Done."))))

    (when (and story focus)
      (ejira-focus-on-issue story))))


(defun ejira-heading-to-subtask (focus)
  "Make the current org-heading into a JIRA subtask.
With prefix argument FOCUS, focus the issue after creating."
  (interactive "P")
  (let* ((heading (save-excursion
                    (if (outline-on-heading-p t)
                        (beginning-of-line)
                      (outline-back-to-heading))
                    (point-marker)))
         (story (ejira--select-story))
         (project-id (ejira--get-project story))
         (key (when project-id (ejira--heading-to-item heading project-id
                                                       ejira-subtask-type-name
                                                       nil
                                                       (parent . ((key . ,story)))))))
    (when (and key focus)
      (ejira-focus-on-issue key))))

(defun ejira-update-project (id &optional shallow)
  "Update all issues in project ID.
If DEEP set to t, update each issue with separate API call which pulls also
comments. With SHALLOW, only update todo status and assignee."
  (ejira--update-project id)

  ;; First, update all items that are marked as unresolved.
  ;;
  ;; Handles cases:
  ;; *local*    | *remote*
  ;; ===========+===========
  ;;            | unresolved
  ;; unresolved | unresolved
  ;; resolved   | unresolved
  ;;
  (mapc (lambda (i) (if shallow
                        (ejira--update-task-light
                         (ejira--alist-get i 'key)
                         (ejira--alist-get i 'fields 'status 'name)
                         (ejira--alist-get i 'fields 'assignee 'displayName))
                      (ejira--update-task (ejira--parse-item i))))
        (apply #'jiralib2-jql-search
               (format "project = '%s' and resolution = unresolved" id)
               (ejira--get-fields-to-sync shallow)))

  ;; Then, sync any items that are still marked as unresolved in our local sync,
  ;; but are already resolved at the server. This should ensure that there are
  ;; no hanging todo items in our local sync.
  ;;
  ;; Handles cases:
  ;; *local*    | *remote*
  ;; ===========+===========
  ;; unresolved | resolved
  ;;
  (let ((keys (mapcar #'car (ejira--get-headings-in-file
                             (ejira--project-file-name id)
                             '(:todo "todo")))))
    (when keys
      (mapc (lambda (i) (if shallow
                            (ejira--update-task-light
                             (ejira--alist-get i 'key)
                             (ejira--alist-get i 'fields 'status 'name)
                             (ejira--alist-get i 'fields 'assignee 'displayName))
                          (ejira--update-task (ejira--parse-item i))))
            (apply #'jiralib2-jql-search
                   (format "project = '%s' and key in (%s) and resolution = done"
                           id (s-join ", " keys))
                   (ejira--get-fields-to-sync shallow)))))

  ;; TODO: Handle issue being deleted from server:
  ;; *local*    | *remote*
  ;; ===========+===========
  ;; unresolved |
  ;; resolved   |
  )

;;;###autoload
(defun ejira-update-my-projects (&optional shallow)
  "Synchronize data on projects listed in `ejira-projects'.
With prefix argument SHALLOW, update only the todo state and assignee."
  (interactive "P")
  (mapc (-rpartial #'ejira-update-project shallow) ejira-projects)
  (message "ejira: operation finished"))

;;;###autoload
(defun ejira-set-deadline (arg &optional time)
  "Wrapper around `org-deadline' which pushes the changed deadline to server.
ARG and TIME get passed on to `org-deadline'."
  (interactive "P")
  (ejira--with-point-on (ejira-issue-id-under-point)
    (org-deadline arg time)
    (when ejira-push-deadline-changes
      (let ((deadline (org-get-deadline-time (point-marker))))
        (jiralib2-update-issue (ejira-issue-id-under-point)
                               `(duedate . ,(when deadline
                                              (format-time-string "%Y-%m-%d"
                                                                  deadline))))))))

;;;###autoload
(defun ejira-set-priority ()
  "Set priority of the issue under point."
  (interactive)
  (ejira--with-point-on (ejira-issue-id-under-point)
    (let ((p (completing-read "Priority: "
                              (mapcar #'car ejira-priorities-alist))))
      (jiralib2-update-issue (ejira-issue-id-under-point)
                             `(priority . ((name . ,p))))
      (org-priority (alist-get p ejira-priorities-alist nil nil #'equal)))))

;;;###autoload
(defun ejira-assign-issue (&optional to-me)
  "Set the assignee of the issue under point.
With prefix-argument TO-ME assign to me."
  (interactive "P")
  (ejira--assign-issue (ejira-issue-id-under-point) to-me))

;;;###autoload
(defun ejira-progress-issue ()
  "Progress the issue under point with a selected action."
  (interactive)
  (ejira--progress-item (ejira-issue-id-under-point)))

;;;###autoload
(defun ejira-if-plan-issue ()
  (interactive)
  (let* ((item (ejira-get-id-under-point))
         (startdate (read-string "Startdatum: " (org-read-date nil nil "++mon")))
         (properties (save-excursion
                       (goto-char (nth 2 item))
                       (org-entry-properties)))
         (effort (read-string "Effort: "(or (cdr (assoc "EFFORT" properties)) "0h"))))
    (jiralib2-if-plan-issue (nth 1 item) startdate effort)
    (ejira--update-task (nth 1 item))))

(defun ejira-if-unplan-issue ()
  (interactive)
  (let ((item (ejira-get-id-under-point)))
    (jiralib2-if-unplan-issue (nth 1 item))
    (ejira--update-task (nth 1 item))))

;;;###autoload
(defun ejira-set-issuetype ()
  "Select a new issuetype for the issue under point."
  (interactive)
  (let* ((id (ejira-get-id-under-point nil t))
         (ejira-type (nth 0 id))
         (key (if (equal ejira-type "ejira-comment")
                  (user-error "Cannot set type of comment")
                (nth 1 id)))
         (type (ejira--select-issuetype)))
    (jiralib2-set-issue-type key  type)
    (ejira--update-task key)))

;;;###autoload
(defun ejira-set-epic ()
  "Select a new epic for issue under point."
  (interactive)
  (ejira--set-epic (ejira-issue-id-under-point)
                   (ejira--select-id-or-nil
                    "Select epic: "
                    (ejira--get-headings-in-agenda-files :type "ejira-epic"))))

;;;###autoload
(defun ejira-focus-on-issue (key)
  "Open an indirect buffer narrowed to issue KEY."
  (interactive)
  (let* ((m (or (ejira--find-heading key)
                (error (concat "no issue: " key))))
         (m-buffer (marker-buffer m))
         (buffer-name (concat "*" key "*"))
         (b (or (get-buffer buffer-name)
                (make-indirect-buffer m-buffer (concat "*" key "*") t))))
    (switch-to-buffer b)
    (widen)
    (outline-show-all)
    (goto-char m)
    (org-narrow-to-subtree)
    (outline-show-subtree)
    (ejira-mode 1)))

;;;###autoload
(defun ejira-focus-on-clocked-issue ()
  "Goto current or last clocked item, and narrow to it, and expand it."
  (interactive)
  (ejira-focus-on-issue (ejira--get-clocked-issue)))


(defun ejira-close-buffer ()
  "Close the current buffer viewing issue details."
  (interactive)
  (kill-buffer (current-buffer))

  ;; Because we are using indirect buffers, killing current buffer will not go
  ;; back to the previous buffer, but instead to the corresponding direct
  ;; buffer. Switching to previous buffer here does the trick.
  ;; (switch-to-prev-buffer)
  )

(defun ejira-insert-link-to-clocked-issue ()
  "Insert link to currently clocked issue into buffer."
  (interactive)
  (insert (format "%s/browse/%s" jiralib2-url (ejira--get-clocked-issue))))

;;;###autoload
(defun ejira-focus-item-under-point ()
  "And narrow to item under point, and expand it."
  (interactive)
  (ejira-focus-on-issue (ejira-issue-id-under-point)))

;;;###autoload
(defun ejira-focus-up-level ()
  "Try to focus the parent item of the item under point."
  (interactive)
  (ejira-focus-on-issue
   (ejira--with-point-on (ejira-issue-id-under-point)
     (org-up-element)
     (ejira-issue-id-under-point))))

;;;###autoload
(defvar ejira-entry-mode-map
  (let ((ejira-map (make-sparse-keymap)))
    (define-key ejira-map (kbd "C-c ka") 'ejira-add-comment)
    (define-key ejira-map (kbd "C-c kd") 'ejira-delete-comment)
    (define-key ejira-map (kbd "C-c iu") 'ejira-pull-item-under-point)
    (define-key ejira-map (kbd "C-c is") 'ejira-push-item-under-point)
    (define-key ejira-map (kbd "C-c ic") 'ejira-create-item-under-point)
    (define-key ejira-map (kbd "C-c pu") 'ejira-update-my-projects)
    (define-key ejira-map (kbd "C-c ds") 'ejira-set-deadline)
    (define-key ejira-map (kbd "C-c ps") 'ejira-set-priority)
    (define-key ejira-map (kbd "C-c ia") 'ejira-assign-issue)
    (define-key ejira-map (kbd "C-c it") 'ejira-progress-issue)
    (define-key ejira-map (kbd "C-c ip") 'ejira-if-plan-issue)
    (define-key ejira-map (kbd "C-c iu") 'ejira-if-unplan-issue)
    (define-key ejira-map (kbd "C-c ii") 'ejira-set-issuetype)
    (define-key ejira-map (kbd "C-c es") 'ejira-set-epic)
    (define-key ejira-map (kbd "C-c if") 'ejira-focus-on-issue)
    (define-key ejira-map (kbd "C-c hs") 'ejira-heading-to-subtask)
    (define-key ejira-map (kbd "C-c ht") 'ejira-heading-to-task)
    ejira-map))

;;;###autoload
(define-minor-mode ejira-mode
  "Ejira Mode"
  "Minor mode for managing JIRA ticket in a narrowed org buffer."
  :init-value nil
  :global nil
  :keymap ejira-entry-mode-map)

(defun ejira--get-first-id-matching-jql (jql)
  "Helper function for `ejira-guess-epic-sprint-fields'.
Return the first item matching JQL."
  (nth 0
       (alist-get 'issues
                  (jiralib2-session-call "/rest/api/2/search"
                                         :type "POST"
                                         :data (json-encode
                                                `((jql . ,jql)
                                                  (startAt . 0)
                                                  (maxResults . 1)
                                                  (fields . ("key"))))))))

(defun ejira-refile (key)
  "Refile heading under point under item KEY."
  (let ((target (or (ejira--find-heading key) (error "Item not found"))))
    (org-refile nil nil
                `(nil ,(buffer-file-name (marker-buffer target)) nil
                      ,(marker-position target)))))

(defun ejira-guess-epic-sprint-fields ()
  "Try to guess the custom field names for epic and sprint."
  (interactive)
  (message "Attempting to auto-configure Ejira custom fields...")
  (let* ((epic-key (alist-get 'key (ejira--get-first-id-matching-jql
                                    (format "type = %s" ejira-epic-type-name))))
         (issue-key (alist-get 'key (ejira--get-first-id-matching-jql
                                     (format "type != %s" ejira-epic-type-name))))
         (epic-meta (jiralib2-session-call
                     (format "/rest/api/2/issue/%s/editmeta" epic-key)))
         (issue-meta (jiralib2-session-call
                      (format "/rest/api/2/issue/%s/editmeta" epic-key)))

         (epic-field (caar (-filter (lambda (field)
                                      (equal (alist-get 'name field) "Epic Link"))
                                    (alist-get 'fields epic-meta))))
         (sprint-field (caar (-filter (lambda (field)
                                        (equal (alist-get 'name field) "Sprint"))
                                      (alist-get 'fields issue-meta))))
         (epic-summary-field (caar (-filter (lambda (field)
                                              (equal (alist-get 'name field) "Epic Name"))
                                            (alist-get 'fields epic-meta)))))
    (setq ejira-epic-field epic-field
          ejira-epic-summary-field epic-summary-field
          ejira-sprint-field sprint-field)
    (message "Successfully configured custom fields")))

(provide 'ejira)
;;; ejira.el ends here
