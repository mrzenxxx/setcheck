#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
gh auth status
repository=mrzenxxx/setcheck
if ! gh repo view "$repository" >/dev/null 2>&1; then
    gh repo create "$repository" --public --description 'Native macOS playlist-to-video utility for YouTube copyright checks and timestamped tracklists / Видео и треклисты для проверки плейлистов на YouTube'
fi
if git remote get-url origin >/dev/null 2>&1; then
    case "$(git remote get-url origin)" in
        https://github.com/mrzenxxx/setcheck.git|https://github.com/mrzenxxx/setcheck|git@github.com:mrzenxxx/setcheck.git) ;;
        *) printf 'origin points to a different repository\n' >&2; exit 1 ;;
    esac
else
    git remote add origin "https://github.com/$repository.git"
fi
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin main
