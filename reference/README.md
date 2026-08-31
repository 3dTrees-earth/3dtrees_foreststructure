# Scientific reference implementation

`Indices_Final_run.R` is the unchanged Julia Gäßler reference script used as
the scientific oracle for this repository.

- File: `reference/Indices_Final_run.R`
- SHA-256: `746d57b4c937001af31e4ccd1b9f14edb5cebb15d46154ad9e20d0ce39f78226`
- Length: 628 lines
- Encoding: UTF-8 with the original CRLF line endings

Do not format, modernize, parameterize or otherwise edit this file. Tests must
verify its SHA-256 before executing it. Production code belongs under `src/`;
the reference file exists only to make scientific comparisons reproducible.

The reference script contains its original local Windows paths. The validation
harness recreates that directory layout inside an isolated container. It does
not require or modify the author's workstation.
