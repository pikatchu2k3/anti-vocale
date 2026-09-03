#!/usr/bin/env bash
# Anti-Vocale Fork (pikatchu2k3/anti-vocale) — automatischer Update-Build-Release-Lauf
# Muster: Futo-Keyboard-M-Pipeline. Zweig main (nicht master!).
# no_agent-Disziplin: Fortschritt -> stderr, stdout LEER bei keinem Update,
# Erfolgs-Summary auf stdout (wird geliefert), Fehler auf stdout + exit 1 (Marker fuer Repair).
# Exit-Codes: 0 = ok, 1 = Fehler
set -euo pipefail

REPO_DIR="/home/mini/anti-vocale"          # etablierter Pfad mit Gradle-Caches + app/libs sherpa AAR
OWNER="pikatchu2k3"
REPO="anti-vocale"
GRADLE_TASK=":app:assembleFdroidDebug"     # fdroid-Debug: applicationId com.antivocale.app.debug (Parallel-Install)
UPSTREAM_BRANCH="main"
ABI_GLOB="app-fdroid-arm64-*debug.apk"     # arm64-v8a fuer das Handy (Glob UNQUOTED lassen!)

GITHUB_TOKEN="${GITHUB_TOKEN:-$(grep '^GITHUB_TOKEN=' ~/.hermes/.env | cut -d= -f2)}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/jdk-21.0.6+7}"
export PATH="$JAVA_HOME/bin:$PATH"
export GRADLE_OPTS="-Dorg.gradle.jvmargs=-Xmx4096m"
MARKER="$HOME/.hermes/anti-vocale-last-error.txt"

cd "$REPO_DIR"

fail() {
  echo "!!! $* !!!"
  echo "$(date '+%F %T') $*" > "$MARKER"
  exit 1
}

# Marker nur bei Erfolg/kein-Update loeschen (fail() schreibt ihn und exit 1)
clear_marker() { rm -f "$MARKER"; }

step() { echo "=== $1 ===" >&2; }

step "[1/6] Upstream holen ($UPSTREAM_BRANCH)"
if ! git fetch upstream "$UPSTREAM_BRANCH" >/dev/null 2>&1; then
  echo "fetch upstream fehlgeschlagen (transient?) — naechste Woche erneut" >&2
  exit 0   # still ueberspringen, kein Marker
fi

# Update-Check ueber merge-base (nicht SHA-Vergleich!): kein neues Upstream-Commit
# genau dann, wenn upstream/main ein Vorfahre von HEAD ist (HEAD traegt immer die
# Custom-Commits, SHA-Vergleich wuerde jede Woche bauen).
if git merge-base --is-ancestor "upstream/$UPSTREAM_BRANCH" HEAD && [ "${FORCE:-0}" != "1" ]; then
  clear_marker
  exit 0   # kein neues Update -> still (leerer stdout = keine Nachricht)
fi

step "[2/6] Upstream mergen"
if ! git merge "upstream/$UPSTREAM_BRANCH" --no-edit >&2; then
  fail "MERGE-KONFLIKT in $REPO_DIR — manuell loesen: git status"
fi

# Tag VOR dem Build berechnen und in die APK backen (Obtainium-Vergleich Tag == versionName)
TAG="v$(date +%Y.%m.%d)"
export VERSION_NAME="$TAG"
export VERSION_CODE="$(date +%Y%m%d)"

step "[3/6] Build ($GRADLE_TASK, $TAG)"
if ! { ./gradlew "$GRADLE_TASK" 2>&1 | tail -25; } >&2; then
  fail "BUILD FEHLGESCHLAGEN (Repair: Log pruefen)"
fi

APK="$(ls -t app/build/outputs/apk/fdroid/debug/${ABI_GLOB} 2>/dev/null | head -1)"
[ -n "$APK" ] && [ -f "$APK" ] || fail "APK nicht gefunden (Glob: $ABI_GLOB)"

# Version-Check: gebackene versionName-Basis MUSS dem Tag entsprechen (sonst Obtainium-Endlosschleife)
AAPT="$(ls -d "$ANDROID_HOME"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1)"
BAKED=$( "$AAPT" dump badging "$APK" 2>/dev/null | grep -oP "versionName='[^']*'" | head -1 | cut -d"'" -f2 )
echo "APK: $APK | versionName=$BAKED (Tag=$TAG)" >&2
case "$BAKED" in
  "$TAG"|"$TAG"*) ;;
  *) fail "versionName '$BAKED' matcht Tag '$TAG' nicht — Build-Env/Commit-Problem" ;;
esac

step "[4/6] Push zum Fork"
git fetch origin "$UPSTREAM_BRANCH" >/dev/null 2>&1 || true
if ! git rebase --rebase-merges "origin/$UPSTREAM_BRANCH" >&2; then
  fail "REBASE auf origin/$UPSTREAM_BRANCH fehlgeschlagen - manuell loesen"
fi
git push origin "$UPSTREAM_BRANCH" 2>&1 | tail -2 >&2

step "[5/6] Release erstellen"
UPSTREAM_HASH=$(git log -1 --format=%h "upstream/$UPSTREAM_BRANCH")
UPSTREAM_DATE=$(git log -1 --format=%cs "upstream/$UPSTREAM_BRANCH")
BODY="Automatischer Build von **anti-vocale** (Upstream \`${UPSTREAM_HASH}\` vom ${UPSTREAM_DATE}) + Custom-Patch (Storage-Permission fuer /storage/...-Broadcasts, Ergebnis-Notification immer, signal-Rename-Fallback).

Parallel-Install als \`com.antivocale.app.debug\` — die offizielle App bleibt unberuehrt.
Updates: Obtainium → Add App → GitHub Releases → https://github.com/${OWNER}/${REPO}"
APK_SIZE=$(stat -c%s "$APK")
MD5=$(md5sum "$APK" | cut -d' ' -f1)

resp=$(curl -s -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  -d "{\"tag_name\":\"$TAG\",\"name\":\"$REPO $TAG\",\"body\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$BODY")}" \
  "https://api.github.com/repos/$OWNER/$REPO/releases")
code=$(echo "$resp" | tail -1)
release_json=$(echo "$resp" | head -n -1)
if [ "$code" != "201" ]; then
  # KEIN -2-Suffix (Obtainium wertet das als Prerelease < Haupt-Tag). Fix: altes Release+Tag loeschen
  # und unter hoherem Datumstag neu anlegen.
  fail "Release-Erstellung fehlgeschlagen (HTTP $code): $(echo "$release_json" | head -c 300)"
fi
RELEASE_ID=$(echo "$release_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")

echo "--- APK hochladen ---" >&2
curl -s -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"$APK" \
  "https://uploads.github.com/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$APK")" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('Asset:', d.get('name'), d.get('size'), 'Bytes')" >&2

clear_marker
echo "✅ Fertig: https://github.com/$OWNER/$REPO/releases/tag/$TAG"
echo "APK: $(basename "$APK") | ${APK_SIZE} Bytes | MD5 ${MD5}"
