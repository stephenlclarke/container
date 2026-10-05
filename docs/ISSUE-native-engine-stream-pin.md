# Issue: align the native Engine stream dependency

## Motivation and context

Long raw exec uploads can overflow the Engine input queue when a slow session
cannot consume stdin. The corrected Engine source backpressures reads and
reconciles early upgrade input, but the Container nested graph still names the
previous source. A mismatched nested revision prevents exact downstream SDK
qualification.

## Required change

Select the same tested enhanced Engine API revision in the Container manifest
and resolved lock. Preserve every unrelated dependency and the existing resolved
origin metadata. Validate the loaded direct requirement and nested revision,
then qualify the SDK through its downstream published-layer producer.

## Compatibility

No Container runtime API, guest, builder or protocol is changed. This
dependency-only alignment does not claim full runtime qualification.
