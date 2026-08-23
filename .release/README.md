# Release adapter adoption

The release adapter is configured for the Wilted iOS product
(`com.zerodelta.wilted.ios`, team `4CJ49V6QHW`) and the
`wilted-app-store-connect-bridge` consumer. It defines the fixed identity,
readiness and local-gate commands, Production archive/sign/artifact checks, and
the credentialed App Store Connect operations with content-addressed evidence
under `.release-state/`. Do not add secrets or executable-selection fields;
credentials remain broker-owned.

Offline checks:

```sh
python3 .release/test_release_adapter.py
python3 -m release_tools audit --repository . --adapter .release/release-adapter.json --plan .release/release-plan.json
```

The shared command never runs an app command during audit. A real broker/Xcode
canary remains a separate first-adoption gate.
