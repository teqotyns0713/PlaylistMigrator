# PlaylistMigrator

将 `QQ 音乐`、`网易云音乐` 的歌单迁移到 `Spotify` 的 PowerShell 工具。

`PlaylistMigrator` 主打两件事：

- 直接粘贴分享链接，把歌单抓取并导入到 Spotify
- 读取本地 `CSV / JSON` 歌单文件，批量匹配并创建 Spotify 歌单

项目只处理歌单元数据与 Spotify 官方 API，不下载音频，不绕过版权保护。

## Highlights

- 零额外依赖，直接使用 PowerShell 运行
- 推荐使用交互模式，不需要每次手写长命令
- 支持 `QQ 音乐` / `网易云音乐` 分享链接
- 支持本地 `CSV`、通用 `JSON`、网易云 `JSON`、QQ 音乐 `JSON`
- 使用 Spotify 官方 `OAuth PKCE` 登录，不需要 `Client Secret`
- 自动生成导入报告与错误日志，便于排查匹配问题
- 内置 Spotify 搜索缓存和轻量节流，减少重复请求和限流风险

## Requirements

- Windows PowerShell `5.1+`
- 一个可用的 Spotify Developer App
- 在 Spotify App 中配置回调地址：

```text
http://127.0.0.1:8898/callback/
```

## Quick Start

1. 复制配置模板：

```powershell
Copy-Item .\config\spotify.sample.json .\config\spotify.json
```

2. 打开 `config\spotify.json`，填入你的 Spotify `Client ID`

示例：

```json
{
  "clientId": "YOUR_SPOTIFY_CLIENT_ID",
  "redirectUri": "http://127.0.0.1:8898/callback/",
  "tokenPath": "../data/spotify-token.json",
  "searchCachePath": "../data/spotify-search-cache.json",
  "requestDelayMs": 350,
  "defaultMarket": "",
  "scopes": [
    "playlist-modify-private",
    "playlist-modify-public"
  ]
}
```

3. 启动推荐的交互模式：

```powershell
.\start-migrator.cmd
```

## Security

- Do not commit `config/spotify.json`, `data/spotify-token.json`, or any file containing Spotify tokens.
- The sample config only contains placeholders. Each user should create and use their own Spotify Developer App.
- The most sensitive value is the Spotify `refreshToken`, because it can be used to refresh access to your Spotify account.
- See [SECURITY.md](SECURITY.md) for what is safe to share and what to do if a token is leaked.

## Recommended Flow

第一次使用时，最顺手的流程通常是：

1. 运行 `.\start-migrator.cmd`
2. 选择 `1`，先登录 Spotify
3. 再次运行 `.\start-migrator.cmd`
4. 选择 `2`
5. 粘贴 QQ 音乐或网易云音乐歌单分享链接
6. 输入你想创建的 Spotify 歌单名称

## Interactive Mode

直接运行：

```powershell
.\start-migrator.cmd
```

会进入菜单：

```text
1. Login to Spotify
2. Import from a playlist link to Spotify
3. Fetch a playlist link and save it as a file
4. Import from a local file to Spotify
5. Inspect a local file
```

如果你只想“粘贴链接然后一步步跟着提示走”，这就是最推荐的用法。

## Command Line Usage

也可以直接使用脚本命令：

```powershell
.\migrate.ps1 help
```

或者查看 PowerShell 帮助：

```powershell
Get-Help .\migrate.ps1 -Detailed
```

### 1. 登录 Spotify

```powershell
.\migrate.ps1 login -OpenBrowser
```

### 2. 从分享链接抓取歌单并保存为导入文件

网易云音乐：

```powershell
.\migrate.ps1 fetch-link -SourceLink "https://music.163.com/playlist?id=26467411"
```

QQ 音乐：

```powershell
.\migrate.ps1 fetch-link -SourceLink "https://y.qq.com/n/ryqq_v2/playlist/9500362286"
```

### 3. 从分享链接直接导入到 Spotify

```powershell
.\migrate.ps1 import-link `
  -SourceLink "https://music.163.com/playlist?id=26467411" `
  -PlaylistName "My Imported Playlist" `
  -OpenBrowser
```

只做匹配预演，不真正创建 Spotify 歌单：

```powershell
.\migrate.ps1 import-link `
  -SourceLink "https://y.qq.com/n/ryqq_v2/playlist/9500362286" `
  -PlaylistName "QQ Music Dry Run" `
  -DryRun `
  -OpenBrowser
```

### 4. 导入本地文件

先检查文件格式：

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

## Supported Share Links

### 网易云音乐

- `https://music.163.com/playlist?id=...`
- `https://music.163.com/#/playlist?id=...`
- `https://music.163.com/m/playlist?id=...`

### QQ 音乐

- `https://y.qq.com/n/ryqq_v2/playlist/...`
- `https://y.qq.com/n/ryqq/playlist/...`
- `https://i.y.qq.com/n2/m/share/details/taoge.html?id=...`
- `https://i2.y.qq.com/n3/other/pages/details/playlist.html?id=...`

也支持直接粘贴分享文案，脚本会自动从文本里提取链接。

## Supported Local Formats

### Generic CSV

```csv
title,artist,album,duration_ms,isrc,id
```

### Generic JSON / 平台 JSON

脚本会尽量识别这些常见字段：

- 歌名
- 歌手
- 专辑
- 时长
- ISRC

仓库里的 `samples/` 提供了可直接参考的示例文件。

## Matching Strategy

Spotify 搜索时会综合使用：

1. `ISRC`
2. `track:"歌名" artist:"歌手"`
3. `track:"歌名" artist:"歌手" album:"专辑"`
4. `歌名 + 歌手`

随后按 `歌名 / 歌手 / 专辑 / 时长` 综合打分。分数过低的歌曲不会被强行导入，而是进入未匹配报告，避免把同名歌曲误加进歌单。

## Output Files

### 抓取后的标准化导入文件

`fetch-link` 默认输出到：

```text
output/imports/<provider>-<playlistId>.json
```

### 导入报告

每次导入后会生成：

```text
output/last-report.json
```

报告中会包含：

- 匹配成功的歌曲
- 未匹配的歌曲
- 生成的 Spotify 歌单链接

### 错误日志

如果登录或导入失败，会写入：

```text
output/last-error.txt
```

这是排查问题时最值得先看的文件。

## Project Structure

- `start-migrator.cmd`: 推荐入口，直接进入交互模式
- `migrate.ps1`: CLI 入口脚本
- `src/PlaylistMigrator.psm1`: 核心抓取、解析、匹配、导入逻辑
- `config/spotify.sample.json`: Spotify 配置模板
- `samples/`: 示例输入文件
- `.github/workflows/ci.yml`: Windows smoke test

## Notes

- 本项目只迁移歌单元数据，不下载音频
- 因版权、地区或 Spotify 收录差异，部分歌曲可能无法匹配
- 如果平台后续调整分享链接或接口结构，抓取逻辑可能需要更新
- 如果想限制 Spotify 搜索市场，可在导入时加 `-Market US` 之类参数
- 大歌单导入会逐首调用 Spotify 搜索 API，终端会显示当前匹配进度
- 如果 Spotify 返回很长的 `429 Retry-After`，工具会停止并提示等待时间，而不是在终端里静默等待数小时
- 默认搜索缓存保存在 `data/spotify-search-cache.json`，想重新匹配时可以删除这个文件
- `requestDelayMs` 控制 Spotify 搜索请求之间的最小间隔，调大更稳，调小更快但更容易触发限流

## Development

当前 CI 会在 Windows runner 上做基础 smoke test：

- `inspect-source csv`
- `inspect-source netease-json`
- `inspect-source qqmusic-json`

本地也可以手动运行同样的检查命令，确认解析器没有回归。

