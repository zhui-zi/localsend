#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -m)" != "aarch64" ]]; then
  echo "This build must run on an aarch64 host." >&2
  exit 1
fi

if [[ "$(getconf GNU_LIBC_VERSION)" != "glibc 2.31" ]]; then
  echo "This build must run against glibc 2.31." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_dir="$repo_root/app"
flutter_root="${FLUTTER_ROOT:-/opt/flutter}"
output_dir="${OUTPUT_DIR:-$repo_root/dist-kylin}"
version="$(sed -n 's/^version: \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' "$app_dir/pubspec.yaml")"
package_name="LocalSend-${version}-kylin-v10-feiteng-d2000-arm64.deb"
stage_dir="$(mktemp -d)"
package_root="$stage_dir/package"

cleanup() {
  rm -rf "$stage_dir"
}
trap cleanup EXIT

if [[ ! -x "$flutter_root/bin/flutter" ]]; then
  git clone --depth 1 --branch 3.41.9 https://github.com/flutter/flutter.git "$flutter_root"
fi

export PATH="$flutter_root/bin:$PATH"
export PUB_CACHE="${PUB_CACHE:-/tmp/localsend-pub-cache}"

git config --global --add safe.directory "$repo_root"
flutter config --enable-linux-desktop

pushd "$app_dir" >/dev/null
flutter pub get
flutter build linux --release
popd >/dev/null

bundle_dir="$app_dir/build/linux/arm64/release/bundle"
test -x "$bundle_dir/localsend_app"

install -d "$package_root/opt/localsend" "$package_root/usr/bin" \
  "$package_root/usr/share/applications" "$package_root/usr/share/icons/hicolor/512x512/apps" \
  "$package_root/DEBIAN"
cp -a "$bundle_dir/." "$package_root/opt/localsend/"

for library in \
  libayatana-appindicator3.so.1 \
  libayatana-indicator3.so.7 \
  libayatana-ido3-0.4.so.0 \
  libdbusmenu-glib.so.4 \
  libdbusmenu-gtk3.so.4; do
  library_path="$(ldconfig -p | awk -v name="$library" '$1 == name { print $NF; exit }')"
  if [[ -z "$library_path" ]]; then
    echo "Missing runtime library: $library" >&2
    exit 1
  fi
  cp -aL "$library_path" "$package_root/opt/localsend/lib/$library"
done

cat > "$package_root/usr/bin/localsend" <<'EOF'
#!/bin/sh
export LD_LIBRARY_PATH="/opt/localsend/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /opt/localsend/localsend_app "$@"
EOF
chmod 0755 "$package_root/usr/bin/localsend"

cat > "$package_root/usr/share/applications/org.localsend.localsend_app.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=LocalSend
GenericName=File Transfer
Comment=Share files securely over the local network
Exec=localsend
Icon=localsend
Terminal=false
Categories=Network;FileTransfer;Utility;
StartupNotify=true
EOF

install -m 0644 "$app_dir/assets/img/logo-512.png" \
  "$package_root/usr/share/icons/hicolor/512x512/apps/localsend.png"

installed_size="$(du -sk "$package_root" | cut -f1)"
cat > "$package_root/DEBIAN/control" <<EOF
Package: localsend
Version: ${version}-1kylin1
Architecture: arm64
Maintainer: LocalSend contributors <dev.tien.donam@gmail.com>
Installed-Size: $installed_size
Depends: libc6 (>= 2.31), libgtk-3-0 (>= 3.24), libstdc++6, xdg-user-dirs
Section: net
Priority: optional
Homepage: https://localsend.org
Description: Local network file sharing for Kylin V10 on Feiteng D2000
 LocalSend shares files securely over the local network without an external server.
 This package targets the aarch64 Feiteng D2000 platform and bundles the tray
 indicator runtime libraries that are not consistently available in Kylin V10.
EOF

find "$package_root" -type d -exec chmod 0755 {} +
mkdir -p "$output_dir"
dpkg-deb --root-owner-group --build "$package_root" "$output_dir/$package_name"

max_glibc="$(find "$package_root/opt/localsend" -type f -exec file {} + \
  | awk -F: '/ELF/ {print $1}' \
  | xargs -r readelf --version-info 2>/dev/null \
  | grep -oE 'GLIBC_[0-9]+\.[0-9]+' \
  | sort -Vu \
  | tail -1)"

if [[ -z "$max_glibc" || "$(printf '%s\n' "$max_glibc" GLIBC_2.31 | sort -V | tail -1)" != "GLIBC_2.31" ]]; then
  echo "Built package exceeds the GLIBC_2.31 compatibility ceiling: ${max_glibc:-unknown}" >&2
  exit 1
fi

dpkg-deb --info "$output_dir/$package_name"
dpkg-deb --contents "$output_dir/$package_name" >/dev/null
sha256sum "$output_dir/$package_name" > "$output_dir/SHA256SUMS"
printf 'Maximum required glibc symbol: %s\n' "$max_glibc"
