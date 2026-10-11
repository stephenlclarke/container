# Native evidence publication rejects a non-secret Swift diagnostic

## Problem

Foundation production and qualification pass, but the release proof builder rejects a compiler source excerpt assigning `uploadSequenceToken` to the property with the same name. Its credential detector matches the suffix `Token = uploadSequenceToken` as if the identifier were a credential value. The refusal occurs during local publication planning, before upload.

## Expected behavior

Keep the exact compiler log bytes in the public proof and preserve original hashes. Recognize only complete Swift diagnostic source lines that assign an unquoted parameter identifier to the identically named property. Continue rejecting credential values, private-key headers, authorization headers and standalone token formats.

## Evidence and impact

The original Foundation production, qualification, publication refusal, private scan locations/hashes, and one-test regression failure are retained in the performance goal evidence. No historical benchmark or published baseline was changed. Without the fix, a valid compiled candidate cannot complete its release chain.
