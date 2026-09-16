# Codev production

This folder is what you take to the server: **no application source code**, only small packages (Compose + env) that **pull published images** and start them.

The product has **three parts**. People use one website (Co-review). Analytics and the coding agent sit behind it.

```text
  Staff browser
       │
       ▼
  Co-review  ──────────►  Open-Hand
  (login, PRs, reviews)    (coding agent, when a review
                            is sent to the external agent)
       │
       └── DevLake + Grafana  (charts on the Analytics page)
```

---

## The three parts

### 1. Co-review (the main application)

The site staff open in the browser: sign in (SSO), connect GitLab/GitHub/Bitbucket, see pull requests, run and read reviews, manage users.

On the server this is the dashboard, the review API, a database, and Git webhook listeners.

**How to build, push, and run:** [co-review/README.md](co-review/README.md)

### 2. DevLake + Grafana (analytics)

This is **not a third zip**. It is started from the **same Co-review package** (an optional group of containers).

- **DevLake** copies history from your Git tools (commits, PRs, and similar).
- **Grafana** draws charts from that data. Co-review embeds those charts on **Analytics**.

Turn it on with the Co-review start script (default). Skip it only if you do not need Analytics: `./scripts/stack-up.sh --skip-devlake` (details in the Co-review README). After it is healthy, run the Grafana dashboard script once, as that README describes.

### 3. Open-Hand (coding agent)

A **separate** application. Co-review can send a review job here when “external agent” is enabled. Open-Hand runs the agent (and pulls a sandbox image when a job starts). It has its own website (LLM settings) and its own port (default **3005**, so it does not clash with Co-review on **3000**).

**How to build, push, and run:** [open-hand/README.md](open-hand/README.md)

Point Co-review `AGENT_EXTERNAL_URL` at Open-Hand (for example `http://<open-hand-host>:3005`). Point Open-Hand’s callback URL back at Co-review’s API. The Open-Hand README has the exact names.

---

## What you deploy (two packages, three capabilities)

| What the client gets | Folder | What it starts |
| --- | --- | --- |
| Package A | [co-review/](co-review/README.md) | Co-review **and**, unless you skip it, **DevLake + Grafana** |
| Package B | [open-hand/](open-hand/README.md) | Open-Hand only |

Suggested order on the server:

1. Start **Co-review** (include DevLake unless you do not want Analytics).
2. Start **Open-Hand**.
3. Fill the URLs that connect them, then try a login and a review.

You do not install Node/Python app source on production. You need **Docker** on the host, Hub login if images are private, and a filled `.env` in each package. SSO and Git tokens are configured in those env files and in the Co-review UI after login.

Replace example Docker Hub user `tuzaku95` with yours in the subfolder READMEs.
