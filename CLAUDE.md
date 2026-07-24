# HikViewer — working rules

- **Don't change things unless explicitly asked.** Default to read-only investigation and proposals; wait for a clear go-ahead before editing files, configs, or devices.
- **NVR and camera credentials are for read-only use only.** Never attempt to change any NVR or camera configuration unless the user has explicitly confirmed that specific change first.
- Never create branches. work on Main 
- Never commit without explicit approval
- **After every code change, run `./build.sh --native`** so `./hikviewer` is fresh and the user can run it straight from this directory — they should never have to build manually. Report any compile errors instead of leaving the tree broken.