# Valid-updated single-file batch, 2026-08-17

## Scope

The production batch reprocesses all 1,313 eligible single-LAZ datasets with
the Julia-faithful, disk-backed ForestStructure path. It publishes a dataset
only after fresh output validation to:

`/mnt/gsdata/projects/3dtrees/forest_structure/valid_updated/{dataset_id}`

The 30 multi-file datasets are recorded separately and are outside this run.
The existing `valid` and `pending_xy_rescale` trees remain unchanged.

## Runtime envelope

- five concurrent Docker containers;
- 15 CPUs and 75 GiB hard memory limit per container;
- no additional swap and no network;
- two LAScatalog workers;
- 70 GiB internal ForestStructure memory guard;
- original single LAZ and AOI mounted read-only;
- candidates and temporary files on `/mnt/ssds/kg281`;
- no automatic retry or automatic scientific fix.

The internal guard previously accepted at most 60 GiB. This change raises
only the validated argument ceiling to 70 GiB and exposes that ceiling in the
image label `earth.3dtrees.memory-budget.max-gib`. The default remains 60 GiB.
The threshold does not change algorithms, parameters, ordering, rasters, CSVs,
or GeoJSON outputs. Five GiB remains outside the internal accounting under the
75 GiB Docker hard limit.

The batch runner reads the image label during preflight and rejects a requested
internal budget above the image's advertised ceiling. This prevents an invalid
configuration from being dispatched to dataset containers.

## Invalid launch retained for audit

An initial launch passed 70 GiB to an image that still enforced the old
60 GiB ceiling. It was stopped immediately after detection. Forty completed
containers and five containers interrupted during shutdown all exited at
argument validation with:

`--memory-budget-gib must be greater than zero and at most 60`

No point cloud entered scientific processing and no dataset was published.
These records are retained as an invalid orchestration launch and are not
classified as dataset failures or retries.

## Scientific release gate

Before the batch, datasets 150, 970, and 2062 matched the Julia reference at
zero tolerance for scientific CSVs and DTM cell values. Their complete lidR
grid geometry was also exact:

- 150: 147 tiles, 397 segments, 77,248 DTM cells;
- 970: 3 tiles, 1,074 segments, 57,840 DTM cells, extent
  `[-1, 239] x [-1, 240]`;
- 2062: 3 tiles, 474 segments, 61,292 DTM cells, extent
  `[-1, 307] x [-1, 198]`.

Because the 70 GiB change is an argument ceiling only, the corrected image is
also required to pass the synthetic acceptance suite at a 70 GiB internal
budget before production dispatch.
