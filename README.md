# PlaylistMigrator

`PlaylistMigrator` 是一个零依赖的 PowerShell 工具，用来把 `QQ 音乐`、`网易云音乐`、`CSV/JSON` 歌单元数据迁移到 Spotify。

它支持两种常见用法：

1. 直接粘贴 `QQ 音乐` / `网易云音乐` 的歌单分享链接
2. 导入你已经准备好的本地 `CSV / JSON` 歌单文件

项目只处理歌曲元数据和 Spotify 官方 API，不下载音频，也不绕过版权保护。

## 特性

- 纯 PowerShell 5.1+，无需 Node.js / Python
- 支持 `QQ 音乐 JSON`、`网易云 JSON`、`通用 JSON`、`CSV`
- 支持直接粘贴 `QQ 音乐` / `网易云音乐` 的歌单分享链接
- 支持交互式终端菜单，不需要每次手打一长串命令
- 使用 Spotify 官方 `OAuth PKCE` 登录，不需要 `Client Secret`
- 自动搜索、匹配并创建 Spotify 歌单
- 支持 `Dry Run` 预演
- 自动生成抓取文件、匹配报告和错误日志
- 内置 GitHub Actions 基础自检

## 推荐用法

### 1. 配置 Spotify

先复制配置模板：

```powershell
Copy-Item .\config\spotify.sample.json .\config\spotify.json
```

然后到 Spotify Developer Dashboard：

1. 创建一个应用
2. 添加 Redirect URI：`http://127.0.0.1:8898/callback/`
3. 把 `Client ID` 写进 `config\spotify.json`

示例：

```json
{
  "clientId": "YOUR_SPOTIFY_CLIENT_ID",
  "redirectUri": "http://127.0.0.1:8898/callback/",
  "tokenPath": "../data/spotify-token.json",
  "defaultMarket": "",
  "scopes": [
    "playlist-modify-private",
    "playlist-modify-public"
  ]
}
```

### 2. 启动交互模式

推荐直接运行：

```powershell
.\start-migrator.cmd
```

然后在菜单里按提示操作：

- `1` 登录 Spotify
- `2` 从歌单链接直接导入到 Spotify
- `3` 抓取歌单链接并保存成导入文件
- `4` 从本地文件导入到 Spotify
- `5` 先检查本地文件格式

### 3. 最常见流程

第一次使用时，最推荐的顺序是：

1. 运行 `.\start-migrator.cmd`
2. 选 `1`，先完成 Spotify 登录
3. 再运行一次 `.\start-migrator.cmd`
4. 选 `2`
5. 粘贴 QQ 音乐或网易云音乐歌单链接
6. 按提示输入 Spotify 歌单名

## 命令行模式

如果你更喜欢命令参数方式，仍然可以直接运行 `migrate.ps1`。

注意：有些机器会拦截直接执行 `.ps1`，这时可以改用：

```powershell
powershell -ExecutionPolicy Bypass -File .\migrate.ps1 ...
```

### 登录 Spotify

```powershell
.\migrate.ps1 login -OpenBrowser
```

### 从分享链接抓取导入文件

网易云：

```powershell
.\migrate.ps1 fetch-link -SourceLink "https://music.163.com/playlist?id=26467411"
```

QQ 音乐：

```powershell
.\migrate.ps1 fetch-link -SourceLink "https://y.qq.com/n/ryqq_v2/playlist/9500362286"
```

### 从分享链接直接导入到 Spotify

```powershell
.\migrate.ps1 import-link `
  -SourceLink "https://music.163.com/playlist?id=26467411" `
  -PlaylistName "迁移到 Spotify" `
  -OpenBrowser
```

只看匹配效果，不真正建歌单：

```powershell
.\migrate.ps1 import-link `
  -SourceLink "https://y.qq.com/n/ryqq_v2/playlist/9500362286" `
  -PlaylistName "QQ Music Dry Run" `
  -DryRun `
  -OpenBrowser
```

### 从本地文件导入

先检查文件：

```powershell
.\migrate.ps1 inspect-source csv -SourcePath .\samples\generic-playlist.csv
.\migrate.ps1 inspect-source netease-json -SourcePath .\samples\netease-playlist.json
.\migrate.ps1 inspect-source qqmusic-json -SourcePath .\samples\qqmusic-playlist.json
```

正式导入：

```powershell
.\migrate.ps1 import qqmusic-json `
  -SourcePath .\samples\qqmusic-playlist.json `
  -PlaylistName "QQ Music Imported" `
  -OpenBrowser
```

## 支持的分享链接

### 网易云音乐

- `https://music.163.com/playlist?id=...`
- `https://music.163.com/#/playlist?id=...`
- `https://music.163.com/m/playlist?id=...`

### QQ 音乐

- `https://y.qq.com/n/ryqq_v2/playlist/...`
- `https://y.qq.com/n/ryqq/playlist/...`
- `https://i.y.qq.com/n2/m/share/details/taoge.html?id=...`

也支持直接粘贴“分享文案”，脚本会自动从文本里提取链接。

## 支持的本地文件格式

### 通用 CSV

```csv
title,artist,album,duration_ms,isrc,id
```

### 网易云 JSON

优先识别：

- `name`
- `artists[].name`
- `album.name`
- `duration`
- `isrc`

### QQ 音乐 JSON

优先识别：

- `songname`
- `singer[].name`
- `albumname`
- `interval`
- `songmid`

## 匹配策略

Spotify 搜索顺序：

1. `ISRC`
2. `track:"歌名" artist:"歌手"`
3. `track:"歌名" artist:"歌手" album:"专辑"`
4. `歌名 + 歌手`

然后按 `歌名 / 歌手 / 专辑 / 时长` 综合打分。低于阈值的歌曲会进入未匹配报告，避免误导入错歌。

## 输出文件

### 标准化导入文件

`fetch-link` 默认会生成：

```text
output/imports/<provider>-<playlistId>.json
```

### 匹配报告

导入后会输出：

```text
output/last-report.json
```

里面包含：

- 匹配成功歌曲
- 未匹配歌曲
- 最终 Spotify 歌单链接

### 错误日志

如果导入或登录失败，会输出：

```text
output/last-error.txt
```

这里通常能看到最关键的报错原因，适合排查登录失败、Spotify API 返回错误、分享链接抓取失败等问题。

## 项目结构

- `start-migrator.cmd`：推荐启动入口
- `migrate.ps1`：CLI 入口
- `src/PlaylistMigrator.psm1`：核心逻辑
- `config/spotify.sample.json`：Spotify 配置模板
- `samples/`：本地导入样例
- `.github/workflows/ci.yml`：GitHub Actions 自检

## GitHub 发布建议

仓库里已经通过 `.gitignore` 排除了这些本地文件：

- `config/spotify.json`
- `data/`
- `output/`

所以你可以安全地提交样例、脚本和文档，而不会把本地 token、报告和抓取结果一起推上去。

推荐发布步骤：

```powershell
git init
git add .
git commit -m "Initial commit"
```

然后推到 GitHub 即可。

## GitHub Actions

当前 CI 会在 Windows runner 上执行样例解析自检：

- `inspect-source csv`
- `inspect-source netease-json`
- `inspect-source qqmusic-json`

这样至少能保证样例输入格式和核心解析器不会在公开仓库里直接坏掉。

## 注意事项

- 本项目不下载歌曲音频，只迁移歌单元数据。
- `fetch-link` 依赖 QQ 音乐和网易云当前仍可访问的公开歌单接口。
- 如果这些平台后续修改页面结构或接口行为，需要更新适配器。
- 如果要限定 Spotify 搜索市场，可以在导入时加 `-Market US` 之类参数。
- 按 Spotify 2026 年 2 月后的开发者规则，新建 Development Mode 应用需要应用所有者拥有 Premium，且每个新应用默认最多 5 个用户。

## 后续可扩展方向

- 支持批量导入多个分享链接
- 增加歌单去重
- 增加同名歌曲人工确认模式
- 增加更多平台导入器
- 增加 GitHub Release 打包脚本
