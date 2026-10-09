<!-- markdownlint-disable MD013 -->

# Harness commits incorrectly invalidate prepared runtime identity

## Motivation and context

After the fresh-scratch harness fix, integration admission failed before testing because action-graph validation used the current harness HEAD in place of the previously compiled product revision. The actual raw build, archive inputs, product hashes and compiler inputs were identical. The only differing field was the graph source commit.

## Required behavior

First require unchanged production source contents, dependency lock and compiler recipe inputs. Then bind the prepared consumer graph to the exact recorded build revision, retaining the strict raw build vector, released archive hashes and staged binary fingerprints. Do not rewrite a historical receipt or rebuild unchanged products for a harness-only commit.
