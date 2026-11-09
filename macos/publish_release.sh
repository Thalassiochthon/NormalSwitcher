#!/bin/bash
# Публикация СОБРАННОГО DMG: GitHub-релиз, зеркало на ruswitcher.app, тап, оживление фида.
# Запускать ПОСЛЕ ./create_dmg.sh [--beta] — он собирает, нотаризует и пишет sha в фид.
#
#   ./publish_release.sh [--beta] --notes FILE [--dry-run] [--no-feed]
#   ./publish_release.sh [--beta] --mirror-only [--dry-run]    # только зеркало сайта
#
# Порядок безопасный и повторяет ручную практику: фид (version*.json в main) оживает
# ПОСЛЕДНИМ — когда DMG уже лежит и на GitHub, и на зеркале, и оба файла, скачанные
# обратно по HTTPS, совпали по sha256 с тем, что записано в фиде. Упал на любом шаге —
# пользователи ничего не увидят, скрипт можно перезапустить: каждый шаг идемпотентен.
#
# Бета: релиз prerelease, фид version-beta.json; анонс в Telegram не срабатывает (он только
# для стабильных). Стабильный: релиз Latest (запускает announce-release.yml), фид version.json,
# каск синхронизируется в тап rashn/homebrew-ruswitcher. Официальный Homebrew бампит их бот.
#
# Доступ к зеркалу: ~/.config/ruswitcher/site.conf (не в репозитории).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

GH_REPO="rashn/RuSwitcher"
TAP_REPO="rashn/homebrew-ruswitcher"
SITE_CONF="${SITE_CONF:-$HOME/.config/ruswitcher/site.conf}"

BETA=0; DRY=0; FEED=1; MIRROR_ONLY=0; NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --beta) BETA=1 ;;
        --dry-run) DRY=1 ;;
        --no-feed) FEED=0 ;;
        --mirror-only) MIRROR_ONLY=1 ;;
        --notes) NOTES="${2:-}"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
    shift
done

die()  { echo "✗ $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }
ok()   { echo "  ✓ $*"; }
# Всё, что меняет мир снаружи, идёт через run: в --dry-run только печатается.
run()  { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

# ---------- что публикуем ----------
if [ "$BETA" = 1 ]; then FEED_FILE="version-beta.json"; CHANNEL="beta"; else FEED_FILE="version.json"; CHANNEL="stable"; fi
IFS='|' read -r VERSION BUILD SHA < <(/usr/bin/python3 -c "
import json; d=json.load(open('$FEED_FILE')); print('|'.join([d['version'], str(d.get('build','')), d.get('sha256','')]))")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]?$ ]] || die "странная версия в $FEED_FILE: $VERSION"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "в $FEED_FILE нет sha256 — сначала ./create_dmg.sh"
if [ "$BETA" = 1 ] && [[ ! "$VERSION" =~ [a-z]$ ]]; then die "бета $VERSION без буквы в конце — перепутан --beta?"; fi
if [ "$BETA" = 0 ] && [[ "$VERSION" =~ [a-z]$ ]]; then die "стабильная $VERSION с буквой — нужен --beta?"; fi

TAG="v$VERSION"
DMG_NAME="RuSwitcher-$VERSION.dmg"
DMG="$SCRIPT_DIR/$DMG_NAME"
GH_ASSET_URL="https://github.com/$GH_REPO/releases/download/$TAG/$DMG_NAME"
if [ "$BETA" = 1 ]; then TITLE="RuSwitcher $VERSION (beta)"; else TITLE="RuSwitcher $VERSION"; fi

echo "Публикация: $TITLE  [$CHANNEL]  sha256 ${SHA:0:12}…"
[ "$DRY" = 1 ] && echo "(режим --dry-run: ничего снаружи не меняется)"

TMPDIR_PUB="$(mktemp -d -t rs-publish)"
cleanup() { hdiutil detach "$TMPDIR_PUB/mnt" -quiet 2>/dev/null || true; rm -rf "$TMPDIR_PUB"; }
trap cleanup EXIT

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Скачать по HTTPS и сверить sha256 (CDN GitHub иногда отдаёт файл не сразу — ретраи).
fetch_and_check() {
    local url="$1" out i
    out="$(mktemp "$TMPDIR_PUB/fetch.XXXXXX")"; FETCHED="$out"
    for i in 1 2 3 4 5 6; do
        if curl -fsSL --max-time 120 -o "$out" "$url" && [ "$(sha_of "$out")" = "$SHA" ]; then
            ok "скачано обратно и совпало: $url"; return 0
        fi
        sleep 5
    done
    die "по $url sha256 не совпал с фидом (или файл недоступен)"
}

# ---------- 1. DMG ----------
step "1. Проверка DMG"
if [ ! -f "$DMG" ]; then
    BETA_FLAG=""; [ "$BETA" = 1 ] && BETA_FLAG=" --beta"
    [ "$MIRROR_ONLY" = 1 ] || die "нет $DMG — сначала ./create_dmg.sh$BETA_FLAG"
    echo "  локального DMG нет — беру опубликованный с GitHub"
    fetch_and_check "$GH_ASSET_URL"
    DMG="$FETCHED"
fi
[ "$(sha_of "$DMG")" = "$SHA" ] || die "sha256 DMG не совпадает с $FEED_FILE"
ok "sha256 совпадает с $FEED_FILE"
codesign --verify "$DMG" 2>/dev/null || die "подпись DMG не проходит codesign --verify"
ok "подпись DMG"
xcrun stapler validate "$DMG" >/dev/null 2>&1 || die "у DMG нет тикета нотаризации (stapler validate)"
ok "тикет нотаризации"
mkdir -p "$TMPDIR_PUB/mnt"
hdiutil attach "$DMG" -nobrowse -readonly -quiet -mountpoint "$TMPDIR_PUB/mnt"
IN_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TMPDIR_PUB/mnt/RuSwitcher.app/Contents/Info.plist")
IN_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TMPDIR_PUB/mnt/RuSwitcher.app/Contents/Info.plist")
hdiutil detach "$TMPDIR_PUB/mnt" -quiet
[ "$IN_VER" = "$VERSION" ] || die "внутри DMG версия $IN_VER, в фиде $VERSION"
[ -z "$BUILD" ] || [ "$IN_BUILD" = "$BUILD" ] || die "внутри DMG build $IN_BUILD, в фиде $BUILD"
ok "внутри DMG приложение $IN_VER (build $IN_BUILD)"
SIZE=$(stat -f%z "$DMG")

# ---------- 2. GitHub ----------
if [ "$MIRROR_ONLY" = 0 ]; then
    step "2. GitHub: тег и релиз"
    gh auth status >/dev/null 2>&1 || die "gh не авторизован"
    HEAD_SHA=$(git rev-parse HEAD)
    LOCAL_TAG=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)
    REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/$TAG" | awk '{print $1}')
    if [ -n "$REMOTE_TAG" ]; then
        REMOTE_COMMIT=$(git rev-parse -q --verify "$REMOTE_TAG^{commit}" 2>/dev/null || echo "$REMOTE_TAG")
        ok "тег $TAG уже на origin (${REMOTE_COMMIT:0:8})"
    else
        if [ -n "$LOCAL_TAG" ] && [ "$LOCAL_TAG" != "$HEAD_SHA" ]; then
            die "локальный тег $TAG указывает на ${LOCAL_TAG:0:8}, а HEAD — ${HEAD_SHA:0:8}"
        fi
        [ -n "$LOCAL_TAG" ] || run git tag "$TAG"
        run git push origin "refs/tags/$TAG"
        ok "тег $TAG → ${HEAD_SHA:0:8}"
    fi

    if gh release view "$TAG" -R "$GH_REPO" >/dev/null 2>&1; then
        REMOTE_ASSET="$(mktemp "$TMPDIR_PUB/remote.XXXXXX")"
        if curl -fsSL --max-time 120 -o "$REMOTE_ASSET" "$GH_ASSET_URL" && [ "$(sha_of "$REMOTE_ASSET")" = "$SHA" ]; then
            ok "релиз $TAG уже есть, ассет на GitHub совпадает — не трогаю"
        else
            echo "  релиз $TAG есть, но ассета нет или он другой — заливаю"
            run gh release upload "$TAG" "$DMG" -R "$GH_REPO" --clobber
        fi
    else
        [ -n "$NOTES" ] || die "релиза $TAG ещё нет — нужен --notes FILE (EN + RU, см. прошлые релизы)"
        [ -f "$NOTES" ] || die "нет файла заметок $NOTES"
        if [ "$BETA" = 1 ]; then
            run gh release create "$TAG" "$DMG" -R "$GH_REPO" --verify-tag --prerelease --title "$TITLE" --notes-file "$NOTES"
        else
            run gh release create "$TAG" "$DMG" -R "$GH_REPO" --verify-tag --latest --title "$TITLE" --notes-file "$NOTES"
        fi
    fi
    if [ "$DRY" = 1 ]; then echo "  [dry-run] скачать $GH_ASSET_URL и сверить sha256"; else fetch_and_check "$GH_ASSET_URL"; fi
fi

# ---------- 3. Зеркало ruswitcher.app ----------
step "3. Зеркало $CHANNEL на ruswitcher.app"
[ -f "$SITE_CONF" ] || die "нет $SITE_CONF (SITE_HOST, SITE_SSH_USER, SITE_KEY, SITE_ROOT, SITE_OWNER, SITE_URL)"
# shellcheck source=/dev/null
. "$SITE_CONF"
# Жёсткие рамки: пишем только в <корень сайта>/download, ничего не удаляем.
[[ "$SITE_ROOT" =~ ^/var/www/[a-z0-9_]+/data/www/[a-z0-9.-]+$ ]] || die "SITE_ROOT вне ожидаемого шаблона: $SITE_ROOT"
[[ "$SITE_OWNER" =~ ^[a-z0-9_]+$ ]] || die "странный SITE_OWNER: $SITE_OWNER"
DL_DIR="$SITE_ROOT/download"
SSH_OPTS=(-i "$SITE_KEY" -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o BatchMode=yes -o ConnectTimeout=15)
SITE="$SITE_SSH_USER@$SITE_HOST"

/usr/bin/python3 - "$TMPDIR_PUB/$CHANNEL.json" "$VERSION" "$BUILD" "$DMG_NAME" "$SIZE" "$SHA" "$SITE_URL" "$GH_REPO" "$TAG" <<'PY'
import json, sys, datetime
out, ver, build, name, size, sha, site, repo, tag = sys.argv[1:]
json.dump({
    "version": ver, "build": build, "file": name,
    "url": f"{site}/download/{name}", "size": int(size), "sha256": sha,
    "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "github": f"https://github.com/{repo}/releases/tag/{tag}",
}, open(out, "w"), ensure_ascii=False, indent=2)
PY

run ssh "${SSH_OPTS[@]}" "$SITE" "mkdir -p '$DL_DIR' && chown '$SITE_OWNER:$SITE_OWNER' '$DL_DIR'"
# Файл заливается под временным именем и переименовывается: никто не скачает половину DMG.
run scp -q "${SSH_OPTS[@]}" "$DMG" "$SITE:$DL_DIR/.$DMG_NAME.part"
run scp -q "${SSH_OPTS[@]}" "$TMPDIR_PUB/$CHANNEL.json" "$SITE:$DL_DIR/.$CHANNEL.json.part"
run ssh "${SSH_OPTS[@]}" "$SITE" "cd '$DL_DIR' && chown '$SITE_OWNER:$SITE_OWNER' '.$DMG_NAME.part' '.$CHANNEL.json.part' \
    && chmod 644 '.$DMG_NAME.part' '.$CHANNEL.json.part' \
    && mv -f '.$DMG_NAME.part' '$DMG_NAME' && mv -f '.$CHANNEL.json.part' '$CHANNEL.json'"
if [ "$DRY" = 1 ]; then
    echo "  [dry-run] скачать $SITE_URL/download/$DMG_NAME и сверить sha256"
else
    fetch_and_check "$SITE_URL/download/$DMG_NAME"
    GOT=$(curl -fsSL --max-time 20 "$SITE_URL/download/$CHANNEL.json" | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['version'])")
    [ "$GOT" = "$VERSION" ] || die "$CHANNEL.json на сайте отдаёт $GOT"
    ok "$SITE_URL/download/$CHANNEL.json → $VERSION"
fi

[ "$MIRROR_ONLY" = 1 ] && { echo; echo "Готово (только зеркало)."; exit 0; }

# ---------- 4. Тап (только стабильный) ----------
if [ "$BETA" = 0 ]; then
    step "4. Homebrew-тап $TAP_REPO"
    grep -q "version \"$VERSION\"" "$SCRIPT_DIR/ruswitcher.rb" && grep -q "sha256 \"$SHA\"" "$SCRIPT_DIR/ruswitcher.rb" \
        || die "macos/ruswitcher.rb не на $VERSION/$SHA — create_dmg.sh не отработал?"
    TAP_FILE_SHA=$(gh api "repos/$TAP_REPO/contents/Casks/ruswitcher.rb" --jq .sha)
    TAP_CONTENT=$(gh api "repos/$TAP_REPO/contents/Casks/ruswitcher.rb" --jq .content | base64 -d)
    if [ "$TAP_CONTENT" = "$(cat "$SCRIPT_DIR/ruswitcher.rb")" ]; then
        ok "тап уже на $VERSION"
    else
        run gh api -X PUT "repos/$TAP_REPO/contents/Casks/ruswitcher.rb" \
            -f message="ruswitcher $VERSION" -f sha="$TAP_FILE_SHA" \
            -f content="$(base64 < "$SCRIPT_DIR/ruswitcher.rb" | tr -d '\n')" --silent
        ok "тап обновлён до $VERSION"
    fi
fi

# ---------- 5. Фид (последним) ----------
if [ "$FEED" = 0 ]; then
    echo; echo "Фид НЕ оживлён (--no-feed). Когда будете готовы: коммит $FEED_FILE в main и push."
    exit 0
fi
step "5. Оживление фида: $FEED_FILE → main"
FEED_FILES=("$FEED_FILE"); [ "$BETA" = 0 ] && FEED_FILES+=("macos/ruswitcher.rb")
if [ "$BETA" = 1 ]; then MSG="beta feed: $VERSION"; else MSG="feed: $VERSION"; fi
BRANCH=$(git branch --show-current)

commit_feed_here() {   # коммитит ТОЛЬКО файлы фида, остальное в дереве не трогает
    if [ "$DRY" = 1 ]; then
        if git diff --quiet HEAD -- "${FEED_FILES[@]}"; then ok "фид уже закоммичен в $BRANCH"
        else echo "  [dry-run] git commit «$1» -- ${FEED_FILES[*]}"; fi
        return 0
    fi
    git add -- "${FEED_FILES[@]}"
    if git diff --cached --quiet -- "${FEED_FILES[@]}"; then ok "фид уже закоммичен в $BRANCH"
    else run git commit -q -m "$1" -- "${FEED_FILES[@]}"; ok "коммит в $BRANCH: $1"; fi
}

if [ "$BRANCH" = "main" ]; then
    commit_feed_here "$MSG"
    git fetch -q origin main
    echo "  в origin/main уйдут коммиты:"; git log --oneline origin/main..main | sed 's/^/    /'
    run git push origin main
else
    [ "$BETA" = 1 ] || die "стабильный релиз публикуется из main (сначала merge бета-ветки)"
    # Бета собирается в своей ветке: sha фиксируется там, а фид кладётся в main через
    # временный worktree — текущую ветку и её рабочее дерево не трогаем.
    commit_feed_here "$MSG sha"
    run git push origin "$BRANCH"
    run git fetch -q origin main
    WT="$TMPDIR_PUB/main"
    run git worktree add -q --detach "$WT" origin/main
    if [ "$DRY" = 1 ]; then
        echo "  [dry-run] скопировать $FEED_FILE в worktree main, коммит «${MSG}», push origin HEAD:main"
    else
        cp "$FEED_FILE" "$WT/$FEED_FILE"
        if git -C "$WT" diff --quiet -- "$FEED_FILE"; then ok "в main фид уже такой"
        else
            git -C "$WT" commit -q -m "$MSG" -- "$FEED_FILE"
            git -C "$WT" push -q origin HEAD:main
            ok "main: $MSG"
        fi
        git worktree remove --force "$WT"
    fi
fi

if [ "$DRY" = 0 ]; then
    RAW="https://raw.githubusercontent.com/$GH_REPO/main/$FEED_FILE"
    for i in 1 2 3 4 5 6; do
        LIVE=$(curl -fsSL --max-time 15 "$RAW?nocache=$RANDOM" | /usr/bin/python3 -c "import json,sys;print(json.load(sys.stdin)['version'])" 2>/dev/null || true)
        [ "$LIVE" = "$VERSION" ] && break; sleep 10
    done
    if [ "$LIVE" = "$VERSION" ]; then ok "фид живой: $RAW → $VERSION"
    else echo "  ! raw.githubusercontent ещё отдаёт ${LIVE:-?} (кэш до 5 мин) — проверьте позже"; fi
fi
echo; echo "Готово: $TITLE опубликован."
