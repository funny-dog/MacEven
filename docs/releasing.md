# 发布流程

与 FinderRight 使用相同约定：在发布机器上使用固定证书构建，`v*` 标签或手动触发 GitHub CI，确认检查通过后上传 DMG、ZIP 和 SHA-256 校验文件。CI 负责检查，发布资产由持有签名私钥的机器生成。

## 1. 版本与签名

- 版本以 `Resources/Info.plist` 为单一来源：更新 `CFBundleShortVersionString`，递增 `CFBundleVersion`。
- 首次运行 `bash scripts/setup-signing.sh`，之后沿用同一张 `MacEven Self-Signed` 证书。用钥匙串访问导出含私钥的 `.p12`，在仓库外安全备份；不要提交私钥。
- 如使用其他证书或钥匙串，通过 `MACEVEN_SIGN_IDENTITY`、`MACEVEN_KEYCHAIN` 指定。发布包必须使用固定证书，不能使用本地调试的 ad-hoc 签名。
- 自签名包未经 Apple 公证，需要在 README 和 Release 说明中写明首次打开方式。

## 2. 验证与打包

在待发布提交上执行：

```bash
# 发布前完整验证：10 万文件、多轮扫描与资源探针；比日常检查耗时更长
bash scripts/verify.sh --full

# 使用同一份源码和固定证书生成安装包，不安装应用
bash scripts/build.sh --package

codesign --verify --strict dist/MacEven.app
codesign -dv dist/MacEven.app
```

确认签名不是 `adhoc`，并与上一正式版保持同一证书。首次公开发布也应保存该签名身份，供后续版本复用。发行包面向 Apple Silicon 时，再检查架构：

```bash
lipo -archs dist/MacEven.app/Contents/MacOS/MacEven
```

产物为：

- `MacEven.dmg`：固定文件名，供 README 的最新版本链接下载。
- `MacEven-v<版本>.zip`：应用内自动更新使用。
- `MacEven-v<版本>.zip.sha256`：ZIP 的 SHA-256 校验文件。

DMG 中包含应用与 `/Applications` 链接；ZIP 根目录必须直接包含 `MacEven.app`。可在打包后验证：

```bash
TASK_VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
shasum -a 256 -c "MacEven-v$TASK_VERSION.zip.sha256"
unzip -l "MacEven-v$TASK_VERSION.zip"
```

## 3. 提交、标签与 CI

确认改动已合并到 `main`、工作区干净，版本号与产物一致。首次发布时，先在 GitHub 创建 `funny-dog/MacEven` 公开仓库并配置 `origin`；不要初始化另一份 README 或 LICENSE。

```bash
TASK_VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
git tag -a "v$TASK_VERSION" -m "MacEven $TASK_VERSION"
git push origin main
git push origin "v$TASK_VERSION"
```

`.github/workflows/ci.yml` 与 FinderRight 一样，仅在推送 `v*` 标签或手动运行时触发。macOS runner 固定使用 Xcode 26.3（避免旧版 Swift 的编译器崩溃），执行 `scripts/verify.sh --fast`，不会替代发布机器上的 full 验证，也不会生成正式签名包或自动公开 Release。

检查该标签对应的 CI 成功后再继续。失败时修复原因并重新验证，不用跳过检查的方式发布。

## 4. 创建并检查 Release

先把用户可读的更新说明写入仓库外文件，说明新增功能、修复、macOS 与架构要求，以及自签名未公证的状态。再创建草稿，附加三项产物：

```bash
TASK_VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
gh release create "v$TASK_VERSION" \
  --repo funny-dog/MacEven \
  --verify-tag \
  --draft \
  --title "MacEven $TASK_VERSION" \
  --notes-file /absolute/path/to/release-notes.md \
  MacEven.dmg \
  "MacEven-v$TASK_VERSION.zip" \
  "MacEven-v$TASK_VERSION.zip.sha256"
```

核对草稿标签指向已验证提交、资源齐全、ZIP 与校验文件同名且对应，并确认 README 的最新 DMG 链接使用固定的 `MacEven.dmg`。确认后公开：

```bash
gh release edit "v$TASK_VERSION" --repo funny-dog/MacEven --draft=false --latest
```

公开后检查 Release 资源、最新 DMG 下载入口和应用更新返回的信息。应用默认从 `funny-dog/MacEven` 的最新正式版检查更新；测试其他仓库可使用 `MACEVEN_UPDATE_REPO=owner/repo`。
