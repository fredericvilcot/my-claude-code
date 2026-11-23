#!/usr/bin/env python3
"""Builds a fake home with made-up Claude Code data, for the README screenshots.

usage: make-demo.py <fake-home> <pid-busy> <pid-waiting> <pid-idle>
The three pids are live processes without a terminal (see docs/screenshots.sh): the app checks that a session's
process is alive. Nothing here comes from a real account.
"""
import json, os, random, sys, time, uuid
from datetime import datetime, timedelta, timezone

home = sys.argv[1]
pids = [int(p) for p in sys.argv[2:5]]
random.seed(7)
now = datetime.now(timezone.utc)
USER = "/Users/alex"

PROJECTS = [
    ("shop-api", "feat/checkout", ["Paiement Stripe et webhooks", "Pagination des commandes", "Cache Redis des paniers"]),
    ("web-app", "main", ["Refonte de l'onboarding", "Mode sombre", "Tableau de bord client"]),
    ("infra", "main", ["Migration vers Postgres 16", "Pipeline de déploiement", "Alertes de latence"]),
    ("landing", "redesign", ["Site vitrine en Astro", "Page tarifs"]),
    ("mobile", "release/2.4", ["Notifications push", "Tests e2e Playwright"]),
]
MODELS = [("claude-opus-5-5", 0.55), ("claude-sonnet-5-5", 0.35), ("claude-haiku-5-5", 0.10)]
TOOLS = [("Edit", "file_path"), ("Read", "file_path"), ("Bash", "command"), ("Grep", "pattern"), ("Write", "file_path")]
FILES = ["src/checkout/session.ts", "src/routes/orders.ts", "app/onboarding/Step2.tsx", "db/migrations/0042.sql",
         "deploy/pipeline.yml", "src/components/Pricing.astro", "lib/push/register.ts", "tests/cart.spec.ts"]

def iso(d): return d.strftime("%Y-%m-%dT%H:%M:%S.") + f"{d.microsecond // 1000:03d}Z"

def model():
    r, acc = random.random(), 0
    for m, w in MODELS:
        acc += w
        if r <= acc: return m
    return MODELS[0][0]

def write_session(project, branch, title, start, replies, end=None, script=None):
    """`end`: when given, the last reply lands exactly then (open sessions end "now")."""
    sid = str(uuid.uuid4())
    gaps = [random.randint(20, 240) for _ in range(replies)]
    if end is not None:
        start = end - timedelta(seconds=sum(gaps) + 60 * len(script or []))
    cwd = f"{USER}/Developer/{project}"
    folder = os.path.join(home, ".claude/projects", cwd.replace("/", "-"))
    os.makedirs(folder, exist_ok=True)
    lines, t, ctx = [], start, 18000
    m = model()
    lines.append({"type": "user", "sessionId": sid, "cwd": cwd, "gitBranch": branch, "timestamp": iso(t),
                  "message": {"role": "user", "content": f"{title} : on s'y met ?"}})
    for i in range(replies):
        t += timedelta(seconds=gaps[i])
        ctx = min(ctx + random.randint(1500, 9000), 190000)
        tool = random.choice(TOOLS) if random.random() < 0.6 else None
        content = [{"type": "tool_use", "id": f"toolu_{uuid.uuid4().hex[:20]}", "name": tool[0],
                    "input": {tool[1]: random.choice(FILES) if tool[1] == "file_path" else
                              ("npm test -- --run" if tool[0] == "Bash" else "TODO")}}] if tool else \
                  [{"type": "text", "text": random.choice(["C'est fait, les tests passent.", "Je regarde la suite.",
                                                           "Voici le correctif proposé.", "Build vert."])}]
        lines.append({"type": "assistant", "sessionId": sid, "cwd": cwd, "gitBranch": branch, "timestamp": iso(t),
                      "requestId": f"req_{uuid.uuid4().hex[:24]}",
                      "message": {"id": f"msg_{uuid.uuid4().hex[:24]}", "role": "assistant", "model": m, "content": content,
                                  "stop_reason": "tool_use" if tool else "end_turn",
                                  "usage": {"input_tokens": random.randint(2, 40), "output_tokens": random.randint(200, 2400),
                                            "cache_read_input_tokens": ctx, "cache_creation_input_tokens": random.randint(500, 4000),
                                            "cache_creation": {"ephemeral_5m_input_tokens": 0,
                                                               "ephemeral_1h_input_tokens": random.randint(500, 4000)}}}})
        if tool:
            lines.append({"type": "user", "sessionId": sid, "cwd": cwd, "timestamp": iso(t),
                          "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": content[0]["id"],
                                                                   "content": "ok"}]}})
    for kind, payload in (script or []):
        t += timedelta(seconds=random.randint(15, 90))
        base = {"sessionId": sid, "cwd": cwd, "gitBranch": branch, "timestamp": iso(t)}
        if kind == "user":
            lines.append({**base, "type": "user", "message": {"role": "user", "content": payload}})
            continue
        if kind == "text":
            content = [{"type": "text", "text": payload}]
        else:   # tool: (name, input, result)
            name, tool_input, result = payload
            content = [{"type": "tool_use", "id": f"toolu_{uuid.uuid4().hex[:20]}", "name": name, "input": tool_input}]
        ctx = min(ctx + random.randint(1500, 6000), 190000)
        lines.append({**base, "type": "assistant", "requestId": f"req_{uuid.uuid4().hex[:24]}",
                      "message": {"id": f"msg_{uuid.uuid4().hex[:24]}", "role": "assistant", "model": m, "content": content,
                                  "stop_reason": "end_turn" if kind == "text" else "tool_use",
                                  "usage": {"input_tokens": 12, "output_tokens": random.randint(300, 1800),
                                            "cache_read_input_tokens": ctx, "cache_creation_input_tokens": 1200,
                                            "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 1200}}}})
        if kind == "tool":
            lines.append({**base, "type": "user", "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": content[0]["id"], "content": payload[2]}]}})
    lines.append({"type": "ai-title", "sessionId": sid, "aiTitle": title})
    path = os.path.join(folder, sid + ".jsonl")
    with open(path, "w") as f:
        f.write("\n".join(json.dumps(l, ensure_ascii=False) for l in lines) + "\n")
    ts = t.timestamp()
    os.utime(path, (ts, ts))
    return sid, t

# History: five weeks of work, mostly on weekdays and working hours.
for day in range(35, 0, -1):
    d = now - timedelta(days=day)
    if d.weekday() >= 5 and random.random() < 0.7: continue
    for _ in range(random.randint(1, 3)):
        project, branch, titles = random.choice(PROJECTS)
        start = d.replace(hour=random.randint(8, 17), minute=random.randint(0, 59))
        write_session(project, branch, random.choice(titles), start, random.randint(8, 45))

# Today: three open sessions and a background job.
open_sessions = [
    ("shop-api", "feat/checkout", "Paiement Stripe et webhooks", "busy", 48, 0.2),
    ("web-app", "main", "Refonte de l'onboarding", "waiting", 30, 4),
    ("infra", "main", "Migration vers Postgres 16", "idle", 22, 25),
]
os.makedirs(os.path.join(home, ".claude/sessions"), exist_ok=True)
WEBHOOK_EDIT_OLD = "  const event = req.body\n  await handle(event)\n  res.sendStatus(200)"
WEBHOOK_EDIT_NEW = ("  const signature = req.headers['stripe-signature']\n"
                    "  let event: Stripe.Event\n"
                    "  try {\n"
                    "    event = stripe.webhooks.constructEvent(req.rawBody, signature, env.STRIPE_WEBHOOK_SECRET)\n"
                    "  } catch (err) {\n"
                    "    return res.status(400).send(`Signature invalide : ${err.message}`)\n"
                    "  }\n"
                    "  if (await alreadyProcessed(event.id)) return res.sendStatus(200)\n"
                    "  await handle(event)\n"
                    "  await markProcessed(event.id)\n"
                    "  res.sendStatus(200)")
FEATURED = [
    ("user", "Les webhooks Stripe arrivent parfois deux fois et on crée des commandes en double. Tu peux sécuriser ça ?"),
    ("text", "Je regarde d'abord comment le webhook est reçu aujourd'hui."),
    ("tool", ("Read", {"file_path": "/Users/alex/Developer/shop-api/src/checkout/webhook.ts"}, "export async function stripeWebhook(req, res) {\n...")),
    ("tool", ("Grep", {"pattern": "constructEvent", "path": "src"}, "No matches found")),
    ("text", "Deux problèmes : la signature Stripe n'est jamais vérifiée, et rien n'empêche de traiter deux fois le même événement. "
             "Je vérifie la signature et je rends le traitement idempotent avec l'identifiant de l'événement."),
    ("tool", ("Edit", {"file_path": "/Users/alex/Developer/shop-api/src/checkout/webhook.ts",
                       "old_string": WEBHOOK_EDIT_OLD, "new_string": WEBHOOK_EDIT_NEW}, "The file has been updated.")),
    ("tool", ("Bash", {"command": "npm test -- checkout", "description": "Lance les tests du paiement"},
              "Test Files  6 passed (6)\n     Tests  42 passed (42)")),
    ("text", "C'est corrigé :\n- la signature de chaque webhook est vérifiée (400 si elle est invalide) ;\n"
             "- un événement déjà traité est ignoré, donc plus de commande en double ;\n- les 42 tests du paiement passent."),
    ("user", "Parfait. Ajoute un test qui envoie deux fois le même événement."),
    ("tool", ("Write", {"file_path": "/Users/alex/Developer/shop-api/tests/webhook.idempotency.spec.ts",
                        "content": "\n".join(["// two identical events, one order"] * 18)}, "File created successfully")),
]
for (project, branch, title, status, replies, minutes_ago), pid in zip(open_sessions, pids):
    sid, _ = write_session(project, branch, title, now, replies, end=now - timedelta(minutes=minutes_ago),
                           script=FEATURED if status == "busy" else None)
    name = f"{project}-{random.randint(10, 60)}"
    with open(os.path.join(home, ".claude/sessions", f"{pid}.json"), "w") as f:
        json.dump({"pid": pid, "sessionId": sid, "cwd": f"{USER}/Developer/{project}", "kind": "interactive",
                   "status": status, "name": name, "startedAt": int(time.time() * 1000),   # after the stand-in process started
                   "updatedAt": int(time.time() * 1000)}, f)

sid, _ = write_session("mobile", "release/2.4", "Tests e2e Playwright", now, 26, end=now - timedelta(minutes=2))
job = sid[:8]
os.makedirs(os.path.join(home, ".claude/jobs", job), exist_ok=True)
with open(os.path.join(home, ".claude/jobs", job, "state.json"), "w") as f:
    json.dump({"state": "working", "sessionId": sid, "daemonShort": job, "name": "Tests e2e Playwright",
               "cwd": f"{USER}/Developer/mobile"}, f)

# Account (plan only) and quotas, as Claude Code's status line and /usage would report them.
with open(os.path.join(home, ".claude.json"), "w") as f:
    json.dump({"oauthAccount": {"organizationType": "claude_max", "userRateLimitTier": "default_claude_max_20x",
                                "hasExtraUsageEnabled": False}}, f)
support = os.path.join(home, "Library/Application Support/My Claude Code")
os.makedirs(support, exist_ok=True)
in2h = int((now + timedelta(hours=2, minutes=12)).timestamp())
in3d = int((now + timedelta(days=3, hours=5)).timestamp())
with open(os.path.join(support, "statusline.json"), "w") as f:
    json.dump({"version": "2.1.330", "model": {"display_name": "Opus 5.5"}, "effort": {"level": "high"},
               "cwd": f"{USER}/Developer/shop-api", "session_name": "shop-api",
               "context_window": {"used_percentage": 41, "total_input_tokens": 82000, "context_window_size": 200000},
               "rate_limits": {"five_hour": {"used_percentage": 38, "resets_at": in2h},
                               "seven_day": {"used_percentage": 57, "resets_at": in3d}}}, f)
with open(os.path.join(support, "last-usage.json"), "w") as f:
    json.dump({"date": time.time(), "windows": [
        {"label": "Current session", "pct": 38, "reset": in2h},
        {"label": "Current week (all models)", "pct": 57, "reset": in3d},
        {"label": "Current week (Sonnet)", "pct": 22, "reset": in3d}]}, f)
os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
with open(os.path.join(home, ".claude/settings.json"), "w") as f:
    json.dump({"permissions": {"defaultMode": "acceptEdits"}, "language": "french"}, f)
print("demo home ready:", home)
