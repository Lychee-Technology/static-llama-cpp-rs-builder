# correctness/fixtures/AGENTS.md

These instructions apply only to committed numerical correctness fixtures.

Also follow `../../AGENTS.md` and `../AGENTS.md`.

Fixture changes alter test evidence, not merely test implementation. Review them
accordingly.

## `golden.tsv`

`golden.tsv` is committed reference data.

Do not regenerate, normalize, reformat, truncate, or replace it as routine cleanup.

A change requires an explicit reason such as:

- an intentional reference-model change;
- an intentional prompt/input methodology change;
- corrected golden-generation methodology;
- new or changed correctness coverage.

When golden values change, verify the generator and model provenance rather than accepting
new output simply because it makes the test pass.

Do not regenerate golden values from the same llama.cpp path being tested when the purpose
of the golden is to provide an independent reference.

## `inputs.tsv`

Input rows define correctness coverage.

Adding, removing, or modifying rows changes what the release gate proves.

Keep changes focused.

Preserve the expected tab-separated schema and valid role values.

Do not delete a difficult input merely because it exposes a regression.

## `reference-model.env`

The reference model URL and SHA256 form a pinned correctness input.

Do not change the URL without updating and independently verifying its checksum.

Do not weaken checksum verification or allow an unpinned reference model.

A reference-model change can invalidate existing golden vectors and therefore requires
review of `golden.tsv` and the correctness methodology.

## Validation after fixture changes

Run the complete correctness pipeline.

For golden/reference-model changes, verify that:

- the model checksum is correct;
- the golden generation path is the intended independent implementation;
- the committed golden corresponds to the intended model and inputs;
- `scripts/correctness.sh` passes for the production artifact.

Do not treat fixture regeneration alone as validation.
