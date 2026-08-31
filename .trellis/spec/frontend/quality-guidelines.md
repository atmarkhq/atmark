# App Quality Guidelines

- Keep SwiftUI work on the UI isolation domain and service traffic in actors;
  `HTTPListener` explicitly avoids the main actor so MCP traffic cannot block UI.
- Preserve accessibility text for icon-only menu and toolbar controls. Prefer
  native controls, keyboard conventions, and semantic labels.
- Test presentation and runtime behavior through protocols/snapshots rather than
  launching real listeners or requesting real TCC permissions. App tests belong
  in `Tests/AtmarkAppTests`; core/server behavior remains in its owning target.
- For settings changes, test success, validation/persistence failure, host update,
  and the rule that the presented mirror advances only after success.
- Keep preview-only substitutes under `PreviewSupport/` and out of production
  runtime ownership.

Verification commands:

```bash
swift test --filter AtmarkAppTests
swift test
swift build
```

No separate linter is configured. Review scene accessibility, actor isolation,
and error copy manually when those areas change.
