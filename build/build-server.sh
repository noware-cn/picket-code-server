#!/usr/bin/env bash
# Build stage of the Picket Code server (upstream calls it `vscode-server`, i.e. reh).
#
# Usage: build-server.sh <source-ref> <version> <vscode-version> [platform] [arch]
#   build-server.sh feat/picket-wsl 1.143.1 1.143.1   -> linux x64
#
# The server version is its own number: it says nothing about the client version,
# and a client only accepts a payload whose `commit` matches its own and whose
# version is at least `product.json.picketServerMinVersion`. `source-ref` is the
# client branch or tag whose patches and extension-removal list build this
# payload; `vscode-version` is the microsoft/vscode tag the client is based on.
set -euo pipefail

SOURCE_REF="${1:?usage: build-server.sh <source-ref> <version> <vscode-version> [platform] [arch]}"
VERSION="${2:?usage: build-server.sh <source-ref> <version> <vscode-version> [platform] [arch]}"
VSCODE_VERSION="${3:?usage: build-server.sh <source-ref> <version> <vscode-version> [platform] [arch]}"
PLATFORM="${4:-linux}"
ARCH="${5:-x64}"

case "$PLATFORM" in
  linux) ;;
  *) echo "Unsupported platform: $PLATFORM (only linux is released; Windows clients connect to a Linux server)" >&2; exit 1 ;;
esac
case "$ARCH" in
  x64|arm64) ;;
  *) echo "Unknown arch: $ARCH (expected x64|arm64)" >&2; exit 1 ;;
esac

# The client parses this with `parseVersion()`, which reads a bare x.y.z and judges
# a leading `v` unparsable — so a tag-shaped value would be a silently unusable
# payload.
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
  echo "Version must be a bare semver without a 'v' prefix (got '$VERSION')" >&2
  exit 1
fi
if ! printf '%s' "$VSCODE_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Upstream vscode version must be a bare x.y.z (got '$VSCODE_VERSION')" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"
CLIENT_REPO="$ROOT_DIR/picket-code"
VSCODE_DIR="$ROOT_DIR/vscode"

echo "==> [server] version=$VERSION source=$SOURCE_REF upstream=$VSCODE_VERSION $PLATFORM-$ARCH"

echo "==> [server] Fetching the client repo at $SOURCE_REF (patch list + removal list)"
rm -rf "$CLIENT_REPO"
git clone --depth 1 --branch "$SOURCE_REF" \
  https://github.com/dantesun/picket-code.git "$CLIENT_REPO"

echo "==> [server] Cloning microsoft/vscode@$VSCODE_VERSION"
rm -rf "$VSCODE_DIR"
git clone --depth 1 --branch "$VSCODE_VERSION" \
  https://github.com/microsoft/vscode.git "$VSCODE_DIR"

echo "==> [server] Trimming built-in extensions to the client's minimal set"
cd "$VSCODE_DIR"
REMOVE_COUNT=0
while IFS= read -r ext; do
  [ -z "$ext" ] && continue
  ext="${ext%$'\r'}"
  if [ -d "extensions/$ext" ]; then
    rm -rf "extensions/$ext"
    REMOVE_COUNT=$((REMOVE_COUNT + 1))
  else
    echo "WARN: extensions/$ext listed but absent upstream" >&2
  fi
done < "$CLIENT_REPO/build/extensions-remove.list"
echo "Removed $REMOVE_COUNT built-in extension dirs"

echo "==> [server] Applying Picket Code patches"
bash "$CLIENT_REPO/build/apply-patches.sh" "$VSCODE_DIR"

echo "==> [server] Installing dependencies (npm ci; retry up to 5 times)"
for i in 1 2 3 4 5; do
  if npm ci --no-audit --no-fund; then
    break
  fi
  if [ "$i" -eq 5 ]; then
    echo "npm ci failed 5 times" >&2
    exit 1
  fi
  echo "npm ci failed $i/5, retrying..." >&2
  sleep $(( 15 * (i + 1) ))
done

echo "==> [server] Building vscode-reh-$PLATFORM-$ARCH-min"
export NODE_OPTIONS="--max-old-space-size=8192"
export VSCODE_PUBLISH_COUNTER=1
npx gulp "vscode-reh-$PLATFORM-$ARCH-min"

# BUILD_ROOT is the parent of the source tree (build/gulpfile.reh.ts:40-41), so the
# packaged folder lands next to vscode/, not inside it.
BUILT="$ROOT_DIR/vscode-reh-$PLATFORM-$ARCH"
[ -d "$BUILT" ] || { echo "Build output missing: $BUILT" >&2; exit 1; }

echo "==> [server] Checking the packaging invariants"
node - "$BUILT/product.json" "$VSCODE_VERSION" <<'NODE'
const fs = require('fs');
const p = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const expected = process.argv[3];
const fail = [];
if (!/^\d+\.\d+\.\d+$/.test(String(p.version))) {
	fail.push(`version must be a bare X.Y.Z, got ${JSON.stringify(p.version)}`);
}
// The payload always carries the upstream version; the server's own version lives
// in the release tag and in the client catalog, never in product.json — an
// extension-compatible version is what every extension checks at load.
if (p.version !== expected) {
	fail.push(`version ${JSON.stringify(p.version)} does not match the upstream ${expected}`);
}
if (p.serverDataFolderName !== '.vscode-server') {
	fail.push(`serverDataFolderName must be .vscode-server, got ${JSON.stringify(p.serverDataFolderName)}`);
}
if (p.serverApplicationName !== 'picket-code-server') {
	fail.push(`serverApplicationName must be picket-code-server, got ${JSON.stringify(p.serverApplicationName)}`);
}
if (fail.length) {
	fail.forEach(f => console.error(`INVARIANT: ${f}`));
	process.exit(1);
}
console.log(`product.json ok: ${p.serverApplicationName} ${p.version} commit ${p.commit}`);
NODE

if find "$BUILT" -maxdepth 4 -name vsda -print -quit | grep -q .; then
  echo "INVARIANT: vsda must not ship — the server would then require signed clients" >&2
  exit 1
fi
echo "vsda absent (unsigned clients are accepted)"

if ! grep -rq "PICKET_ICODE_BIN" "$BUILT/out"; then
  echo "INVARIANT: the iCode provider is missing from out/ (patch 63 not applied?)" >&2
  exit 1
fi
echo "iCode provider present in out/"

echo "==> [server] Packaging"
PACKAGE_NAME="picket-code-server-linux-$ARCH"
STAGE="$ROOT_DIR/.stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -a "$BUILT" "$STAGE/$PACKAGE_NAME"

mkdir -p "$RELEASE_DIR"
ARCHIVE="picket-code-server-$VERSION-linux-$ARCH.tar.gz"
rm -f "$RELEASE_DIR/$ARCHIVE"
tar -czf "$RELEASE_DIR/$ARCHIVE" -C "$STAGE" "$PACKAGE_NAME"
( cd "$RELEASE_DIR" && sha256sum "$ARCHIVE" > "picket-code-server-$VERSION-SHA256SUMS" )

echo "==> [server] Done: $RELEASE_DIR/$ARCHIVE"
ls -lh "$RELEASE_DIR/$ARCHIVE" "$RELEASE_DIR/picket-code-server-$VERSION-SHA256SUMS"
