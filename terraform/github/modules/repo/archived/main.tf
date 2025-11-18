resource "github_repository" "repo" {
  name = var.repository.name

  archive_on_destroy = true
  archived           = true
  visibility         = var.repository.visibility

  lifecycle {
    ignore_changes = [
      allow_auto_merge,
      allow_merge_commit,
      allow_rebase_merge,
      allow_squash_merge,
      description,
      fork,
      has_downloads,
      has_issues,
      has_projects,
      has_wiki,
      homepage_url,
      merge_commit_message,
      merge_commit_title,
      source_owner,
      source_repo,
      squash_merge_commit_message,
      squash_merge_commit_title,
    ]
  }
}
