#!/usr/bin/env python3
"""One-time TestFlight setup for PaloAlly, after the App Store Connect app
record exists (the API can't create apps; do that once in the web UI).

Creates an internal beta group "Internal" with access to every build and adds
the given App Store Connect users to it as internal testers. Safe to re-run.

  python3 scripts/testflight-setup.py [email ...]   # default: styleshang@outlook.com

Uses the App Store Connect API client from the appstore-submit skill
(~/.claude/skills/appstore-submit/scripts/asc.py), which signs with the admin
API key in ~/Documents/个人项目/开发者证书/.
"""
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.claude/skills/appstore-submit/scripts"))
from asc import req  # noqa: E402

BUNDLE_ID = "com.novashang.paloally"
GROUP = "Internal"
emails = sys.argv[1:] or ["styleshang@outlook.com"]

st, apps = req("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")
if st != 200 or not apps.get("data"):
    sys.exit(f"No App Store Connect app for {BUNDLE_ID} yet: create it first "
             "(App Store Connect → Apps → + → New App, iOS, bundle ID com.novashang.paloally).")
app_id = apps["data"][0]["id"]
print(f"app {app_id}")

# The group
st, groups = req("GET", f"/v1/apps/{app_id}/betaGroups?limit=50")
group = next((g for g in groups.get("data", []) if g["attributes"]["name"] == GROUP), None)
if group is None:
    st, r = req("POST", "/v1/betaGroups", {"data": {
        "type": "betaGroups",
        "attributes": {"name": GROUP, "isInternalGroup": True, "hasAccessToAllBuilds": True},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    if st >= 300:
        sys.exit(f"creating the group failed: {st} {r}")
    group = r["data"]
    print(f"created group {GROUP} ({group['id']})")
else:
    print(f"group {GROUP} exists ({group['id']})")

# Internal testers must be App Store Connect users of the team.
st, users = req("GET", "/v1/users?limit=50")
known = {u["attributes"]["username"].lower(): u for u in users.get("data", [])}
for email in emails:
    u = known.get(email.lower())
    if u is None:
        print(f"skip {email}: not an App Store Connect user of this team")
        continue
    a = u["attributes"]
    st, r = req("POST", "/v1/betaTesters", {"data": {
        "type": "betaTesters",
        "attributes": {"email": email, "firstName": a.get("firstName") or "", "lastName": a.get("lastName") or ""},
        "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}}}})
    if st < 300:
        print(f"added {email} to {GROUP}")
    elif st == 409:
        print(f"{email}: already a tester ({r.get('errors', [{}])[0].get('detail', '')})")
    else:
        print(f"{email}: {st} {r}")

print("Done. Builds uploaded by .github/workflows/release-ios.yml appear in the TestFlight app "
      "for these testers once App Store Connect finishes processing them.")
