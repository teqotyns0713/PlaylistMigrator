# Security Policy

This project uses Spotify OAuth PKCE and stores credentials locally. Please keep personal credentials out of commits, issues, screenshots, and support logs.

## What Not To Commit

Never commit these files:

```text
config/spotify.json
data/spotify-token.json
data/spotify-search-cache.json
output/
```

The repository `.gitignore` already excludes them:

```text
config/spotify.json
data/
output/
config/output/
```

Before publishing changes, you can check what Git will commit:

```powershell
git status --short
git ls-files
```

## Spotify Values

`Client ID` is not a password, but it still identifies your Spotify Developer App. Avoid publishing your personal Client ID in a public repository. Each user should create their own Spotify Developer App and put their own Client ID in `config/spotify.json`.

`Client Secret` is not used by this project. The tool uses Spotify's Authorization Code with PKCE flow, which is designed for local/public clients that cannot safely store a secret.

`accessToken` and `refreshToken` are sensitive. A leaked refresh token may allow someone to keep refreshing access to your Spotify account until you revoke it.

## If You Leak A Token

1. Go to your Spotify account apps page and remove access for the affected app.
2. Delete the local token file:

```powershell
Remove-Item .\data\spotify-token.json
```

3. Run login again:

```powershell
.\migrate.ps1 login -OpenBrowser
```

4. If the token was committed to GitHub, remove it from the repository history or make the repository private until the history is cleaned.

## If You Leak A Client ID

If only the Client ID was exposed, your Spotify account is not directly compromised. However, someone could reuse your Developer App ID and consume its API quota or make your app name appear in their authorization flow.

Recommended actions:

1. Create a new Spotify Developer App.
2. Put the new Client ID in your local `config/spotify.json`.
3. Keep `config/spotify.json` untracked.

## Reporting Security Issues

Please do not open a public issue containing tokens, Client IDs, private Spotify account data, or screenshots that show credentials. If you are using your own fork, rotate the leaked value first, then open an issue with the sensitive values removed.
