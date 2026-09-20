# Source pairs flagged for examination

## flagged as exception (score 0.87): N02 vs N03

### N02  (Node v22.20.0 docs)
title: --env-file=file (Node v22.20.0 CLI docs)
url: https://nodejs.org/docs/v22.20.0/api/cli.html

History
Version Changes
v21.7.0, v20.12.0 Add support to multi-line values.
v20.6.0 Added in: v20.6.0
Stability: 1.1 - Active development
Loads environment variables from a file relative to the current directory, making them available to applications on process.env. The environment variables which configure Node.js, such as NODE_OPTIONS, are parsed and applied. If the same variable is defined in the environment and in the file, the value from the environment takes precedence.
You can pass multiple --env-file arguments. Subsequent files override pre-existing variables defined in previous files.
An error is thrown if the file does not exist.
node --env-file=.env --env-file=.development.env index.js

### N03  (Node v22.20.0 docs)
title: --env-file-if-exists=file (Node v22.20.0 CLI docs)
url: https://nodejs.org/docs/v22.20.0/api/cli.html

--env-file-if-exists=file
Added in: v22.9.0
Stability: 1.1 - Active development
Behavior is the same as --env-file, but an error is not thrown if the file does not exist.
--env-file=file
History
Version Changes
v21.7.0, v20.12.0 Add support to multi-line values.
v20.6.0 Added in: v20.6.0

## flagged as exception (score 0.75): N06 vs N07

### N06  (Node v22.5.1 docs)
title: --experimental-sqlite (Node v22.5.1 CLI docs)
url: https://nodejs.org/docs/v22.5.1/api/cli.html

--experimental-sea-config
Added in: v20.0.0
Stability: 1 - Experimental
Use this flag to generate a blob that can be injected into the Node.js binary to produce a single executable application. See the documentation about this configuration for details.
--experimental-shadow-realm
Added in: v19.0.0, v18.13.0
Use this flag to enable ShadowRealm support.
--experimental-sqlite
Added in: v22.5.0
Enable the experimental node:sqlite module.

### N07  (Node v22.20.0 docs)
title: --no-experimental-sqlite (Node v22.20.0 CLI docs)
url: https://nodejs.org/docs/v22.20.0/api/cli.html

--no-experimental-require-module
History
Version Changes
v22.12.0 This is now false by default.
v22.0.0 Added in: v22.0.0
Stability: 1.1 - Active Development
Disable support for loading a synchronous ES module graph in require(). See Loading ECMAScript modules using require().
--no-experimental-sqlite
History
Version Changes
v22.13.0 SQLite is unflagged but still experimental.
v22.5.0 Added in: v22.5.0
Disable the experimental node:sqlite module.
--no-experimental-strip-types
History
Version Changes
v22.18.0 Type stripping is enabled by default.
v22.6.0 Added in: v22.6.0

## flagged as exception (score 0.64): N02 vs N04

### N02  (Node v22.20.0 docs)
title: --env-file=file (Node v22.20.0 CLI docs)
url: https://nodejs.org/docs/v22.20.0/api/cli.html

History
Version Changes
v21.7.0, v20.12.0 Add support to multi-line values.
v20.6.0 Added in: v20.6.0
Stability: 1.1 - Active development
Loads environment variables from a file relative to the current directory, making them available to applications on process.env. The environment variables which configure Node.js, such as NODE_OPTIONS, are parsed and applied. If the same variable is defined in the environment and in the file, the value from the environment takes precedence.
You can pass multiple --env-file arguments. Subsequent files override pre-existing variables defined in previous files.
An error is thrown if the file does not exist.
node --env-file=.env --env-file=.development.env index.js

### N04  (Node v24.8.0 docs)
title: --env-file=file: multi-line values and export keyword (Node v24.8.0 CLI docs)
url: https://nodejs.org/docs/v24.8.0/api/cli.html

Values can start and end with the following quotes: `, " or '. They are omitted from the values.
USERNAME="nodejs" # will result in `nodejs` as the value.
Multi-line values are supported:
MULTI_LINE="THIS IS
A MULTILINE"
# will result in `THIS IS\nA MULTILINE` as the value.
Export keyword before a key is ignored:
export USERNAME="nodejs" # will result in `nodejs` as the value.
If you want to load environment variables from a file that may not exist, you can use the --env-file-if-exists flag instead.

## flagged as exception (score 0.62): N10 vs N11

### N10  (Node v18.20.4 docs)
title: fs.watch() Caveats: recursive option platform support (Node v18.20.4 docs)
url: https://nodejs.org/docs/v18.20.4/api/fs.html

Caveats
The fs.watch API is not 100% consistent across platforms, and is unavailable in some situations.
The recursive option is only supported on macOS and Windows. An ERR_FEATURE_UNAVAILABLE_ON_PLATFORM exception will be thrown when the option is used on a platform that does not support it.
On Windows, no events will be emitted if the watched directory is moved or renamed. An EPERM error is reported when the watched directory is deleted.
Availability
This feature depends on the underlying operating system providing a way to be notified of file system changes.

### N11  (Node v20.19.0 docs)
title: fs.watch() Caveats: recursive restriction removed (Node v20.19.0 docs)
url: https://nodejs.org/docs/v20.19.0/api/fs.html

Caveats
The fs.watch API is not 100% consistent across platforms, and is unavailable in some situations.
On Windows, no events will be emitted if the watched directory is moved or renamed. An EPERM error is reported when the watched directory is deleted.
Availability
This feature depends on the underlying operating system providing a way to be notified of file system changes.
On Linux systems, this uses inotify(7).
On BSD systems, this uses kqueue(2).
On macOS, this uses kqueue(2) for files and FSEvents for directories.
On SunOS systems (including Solaris and SmartOS), this uses event ports.
On Windows systems, this feature depends on ReadDirectoryChangesW.
