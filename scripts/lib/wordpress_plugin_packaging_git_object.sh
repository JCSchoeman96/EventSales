#!/usr/bin/env bash
# Shared git object guards for WordPress plugin packaging (sourced, not executed directly).

# validate_wordpress_packaging_git_object <mode> <objtype> <git-path>
# Returns 0 when the object may be packaged; prints reason and returns 1 when rejected.
validate_wordpress_packaging_git_object() {
  local mode="$1"
  local objtype="$2"
  local git_path="$3"

  if [[ "$objtype" != "blob" ]]; then
    echo "Rejected git object type ${objtype} at ${git_path}" >&2
    return 1
  fi
  if [[ "$mode" == "120000" ]]; then
    echo "Rejected symlink at ${git_path}" >&2
    return 1
  fi
  if [[ "$mode" != "100644" && "$mode" != "100755" ]]; then
    echo "Rejected unexpected git mode ${mode} at ${git_path}" >&2
    return 1
  fi

  return 0
}
