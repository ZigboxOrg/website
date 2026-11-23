# zigbox.org

The source of [zigbox.org](https://zigbox.org): the landing page and the error-code pages of
[Zigbox](https://github.com/ZigboxOrg/zigbox) and [Zigcube](https://github.com/ZigboxOrg/zigcube).
See [AGENTS.md](AGENTS.md) for the layout.

It is deployed to a Cloudflare Worker by `.github/workflows/deploy.yml` (`wrangler.jsonc`) on
every push to `main`, and by a run every 15 minutes whenever ZigboxOrg/zigbox, ZigboxOrg/zigcube
or the newest Zigbox release's package repositories changed since the last deploy
(`/deploy-stamp.txt` says what is deployed).
