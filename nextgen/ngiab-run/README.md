# ngiab-run

Runs NextGen (ngen + t-route) on an NGIAB run folder from ngiab-preprocess and returns
the folder with `outputs/ngen` and `outputs/troute` filled in.

- Image: `awiciroh/ciroh-ngen-image` v2.1.0, pinned by digest
  (https://github.com/CIROH-UA/NGIAB-CloudInfra)
- No `baseCommand`: the arguments go to the image's ENTRYPOINT, `/ngen/HelloNGEN.sh`,
  in auto mode: `<run dir> auto <cores> local`
- `coresMin` is the number of MPI processes
- The run folder is staged as a writable copy because ngen writes into it

TODO: measure RAM on a real run.
