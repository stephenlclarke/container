<!-- markdownlint-disable MD013 -->

# test(run): request explicit prewarm in finite-input fixture

## Motivation and implementation

The prewarmed dedicated EOF regression must opt into the background bootstrap it observes. Add --prewarm to its existing create command and clarify the comment. Production sources, dependency locks, build recipes and expected runtime behavior are unchanged.

## Validation

The full Run layer must pass, including all three original finite-input routes and the explicit bootstrap-success observation. Continue the remaining layers and combine independently authenticated successful layer evidence. Preserve the initial failed report. Retained release benchmarks remain bound to ee7762a6; the corrected test revision is recorded separately.

## Compatibility and risks

This corrects test setup without weakening the timeout or replacing the prewarmed route with a cold fallback. No runtime behavior, timing threshold or historical baseline changes. Full candidate qualification remains pending until the remaining layer gates pass.

## Linked work

See ISSUE-prewarm-eof-fixture.md and the active Container PR 292.
