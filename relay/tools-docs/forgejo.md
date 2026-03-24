## Forgejo (Git)

Git hosting at `{{FORGE_URL}}`. Your API token is at `~/.forgejo-token`.

**Git operations** use SSH — clone, push, pull work via your provisioned SSH key.

**API access** for PRs, issues, etc.:
```
curl -H "Authorization: token $(cat ~/.forgejo-token)" {{FORGE_URL}}/api/v1/repos/...
```

**Common API endpoints:**
| Method | Path | What it does |
|--------|------|-------------|
| GET | `/api/v1/repos/{owner}/{repo}` | Repo info |
| GET | `/api/v1/repos/{owner}/{repo}/pulls` | List PRs |
| POST | `/api/v1/repos/{owner}/{repo}/pulls` | Create PR (`{"title": "...", "head": "branch", "base": "main"}`) |
| GET | `/api/v1/repos/{owner}/{repo}/issues` | List issues |
| POST | `/api/v1/repos/{owner}/{repo}/issues/{id}/comments` | Comment on issue |
