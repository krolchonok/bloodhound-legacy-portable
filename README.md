# bloodhound-legacy-portable

One-script portable launcher for BloodHound Legacy 4.3.1: Neo4j 4.4 + JRE 17 + GUI, all downloaded into `./bhl` next to the script. No Docker needed in the normal path.

```bash
git clone https://github.com/krolchonok/bloodhound-legacy-portable
cd bloodhound-legacy-portable
./bloodhound-legacy.sh up
```

GUI login: `bolt://127.0.0.1:7687`, user `neo4j`, password `bloodhound`.

First run downloads about 270 MB, later runs are offline. After setup the folder is self-contained: `bhl/run.sh` starts everything and `bhl` can be moved or copied.

Commands: `up`, `gui`, `start`, `stop`, `status`, `setup`, `clean`.
Env: `BHL_NEO4J_PASSWORD`, `BHL_BOLT_PORT`, `BHL_HTTP_PORT`, `BHL_HEAP`.

Requirements: Linux x64, curl, unzip, a graphical session for the GUI. If `dist.neo4j.org` is unreachable, the script extracts Neo4j and its JDK from the `neo4j:4.4` Docker image instead (needs Docker, image is removed afterwards), or you can drop `neo4j-community-*-unix.tar.gz` into `bhl/`.
