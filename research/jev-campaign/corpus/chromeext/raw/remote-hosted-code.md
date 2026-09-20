<!-- url: https://developer.chrome.com/docs/extensions/develop/migrate/remote-hosted-code -->
<!-- fetched: 2026-09-17 -->

-

Home

-

Docs

-

Chrome Extensions

-

Develop

##
Deal with remote hosted code violations

Stay organized with collections

Save and categorize content based on your preferences.

Remotely hosted code, or RHC, is what the Chrome Web Store calls anything that
is executed by the browser that is loaded from someplace other than the
extension's own files. Things like JavaScript and WASM. It does not include
data or things like JSON or CSS.

## Why is RHC no longer allowed?

With Manifest V3 extensions now need to bundle all code they are using inside
the extension itself. In the past, you could dynamically inject script tags from
any URL on the web.

## I was told my extension has RHC. What's going on?

If your extension was rejected during review with a Blue Argon error, then
our reviewers believe that your extension is using remotely hosted code. This is
usually the result of an extension trying to add a script tag with a remote
resource (i.e. from the open web, rather than the files included in the
extension), or fetching a resource to execute directly.

## How to spot RHC

Spotting RHC isn't particularly difficult once you know what to look for. First,
check for the strings "http://" or "https://" in your project. If you have an
RHC violation, then you would likely be able to locate them by finding that. If
you have a full build system, or use dependencies from npm or other third
party sources, make sure you are searching the compiled version of the code,
since that is what is being evaluated by the store. If you are still unable to
find the problem, then the next step is to contact One Stop Support . They
will be able to outline the specific violations, and what is needed to get the
extension published as soon as possible.

## What to do if a library is requesting the code

Regardless of where the code comes from, it is not allowed to have RHC. This
includes code you didn't author, but just happen to use as a dependency in your
project. Some developers using Firebase had this issue when remote
code was being included for use in Firebase Auth . Even though this was a
first party (i.e. Google owned) library, no exception is given for RHC. You need
to configure the code to either remove the RHC or update your project to not
include the code to begin with. If you hit an issue where it isn't your code
that is loading RHC, but a library that you are using, then the best course of
action is to contact the library's author. Let them know that this is happening,
and ask for either a workaround or code updates to remove it.

## What if you can't wait for a library update

Some libraries will ship an update almost immediately after being notified, but
others may be abandoned or take time to address the issue. Depending on what
is happening in the specific violation, you may not need to wait for them to
move to be unblocked and complete a successful review. There are a number of
options available to get back up and running quickly.

## Audit the code

Are you certain that the code that is causing the request is needed? If it can
just be deleted, or a library that is causing it can be removed, then delete
that code, and the job is done.

Alternatively, is there another library that offers the same features? Try
checking npmjs.com , GitHub, or other sites for other options that fulfill
the same use cases.

## Tree shaking

If the code causing the RHC violation isn't actually being used, then it may be
able to be automatically deleted by tooling. Modern build tools like
webpack , Rollup , and Vite (just to name a few) have a feature
called tree-shaking . Once enabled on your build system, tree shaking
should remove any unused code paths. This can mean that you not only have a more
compliant version of your code, but a leaner and faster one too! It is important
to note that not all libraries are able to be tree shaken, but many are. Some
tools, like Rollup and Vite, have tree-shaking enabled by default. webpack
needs to be configured for it to be enabled. If you aren't using a build
system as a part of your extension, but are using code libraries, then you are
really encouraged to investigate adding a build tool to your workflow. Build
tools help you write safer, more reliable and more maintainable projects.

The specifics of how to implement treeshaking depend on your specific project.
But to take a simple example with Rollup, you can add treeshaking just by
compiling your project code. For example, if you have a file that only logs into
Firebase Auth, called main.js:

import { GoogleAuthProvider , initializeAuth } from "firebase/auth" ;

chrome . identity . getAuthToken ({ 'interactive' : true }, async ( token ) => {
const credential = GoogleAuthProvider . credential ( null , token );
try {
const app = initializeApp ({ ... });
const auth = initializeAuth ( app , { popupRedirectResolver : undefined , persistence : indexDBLocalPersistence });
const { user } = await auth . signInWithCredential ( credential )
console . log ( user )
} catch ( e ) {
console . error ( error );
}
});

Then all you would need to do is tell Rollup the input file, a plugin needed to
load node files @rollup/plugin-node-resolve , and the name of the output
file it is generating.

npx rollup --input main.js --plugin '@rollup/plugin-node-resolve' --file compiled.js

Running that command in a terminal window, you will receive a generated version
of our main.js file, all compiled into a single file named compiled.js .

Rollup can be simple, but it is also very configurable. You can add all kinds
of complex logic and configuration, just check out their documentation .
Adding build tooling like this will result in a smaller, more efficient code,
and in this case, fixes our remote hosted code issue.

## Automatically editing files

An increasingly common way that remotely hosted code can enter your codebase is
as a subdepenency of a library you are including. If library X wants to
import library Y from a CDN, then you will still need to update it to make
it load from a local source. With modern build systems, you can trivially create
plugins to extract a remote reference, and inline it directly into your code.

That would mean that given code that looks like this:

import moment from "https://unpkg.com/moment@2.29.4/moment.js"
console . log ( moment ())

You could make a small rollup plugin.

import { existsSync } from 'fs' ;
import fetch from 'node-fetch' ;

export default {
plugins : [{
load : async function transform ( id , options , outputOptions ) {
// this code runs over all of out javascript, so we check every import
// to see if it resolves as a local file, if that fails, we grab it from
// the network using fetch, and return the contents of that file directly inline
if ( ! existsSync ( id )) {
const response = await fetch ( id );
const code = await response . text ();

return code
}
return null
}
}]
};

Once you run the build with the new plugin, every remote import URL is
discovered regardless of whether or not it was our code, a subdependency,
subsubdependency, or anywhere else.

npx rollup --input main.js --config ./rollup.config.mjs --file compiled.js

## Manually editing files

The simplest option is just to delete the code that is causing the RHC. Open in
your text editor of choice, and delete the violating lines. This generally is
not that advisable, because it is brittle and could be forgotten. It makes
maintaining your project harder when a file called "library.min.js" isn't
actually library.min.js. Instead of editing the raw files, a slightly more
maintainable option is to use a tool like patch-package . This is a super
powerful option that lets you save modifications to a file, rather than the
file itself. It is built on patch files , the same sort of thing that
powers version control systems like Git or Subversion . You just need
to manually modify the violating code, save the diff file, and configure
patch-package with the changes you want to apply. You can read a full tutorial
on the project's readme . If you are patching a project, we really
encourage you to reach out to the project to request that changes be made
upstream. While patch-package makes managing patches a lot easier, having
nothing to patch is even better.

## What to do if the code isn't being used

As codebases grow, dependencies (or dependency of a dependency, or dependency
of…) can keep code paths that are no longer being used. If one of those sections
includes code to load or execute RHC, then it will have to be removed. It
doesn't matter if it is dead or unused. If it isn't being used it should be
removed, either by treeshaking, or patching the library to remove it.

## Is there any workaround?

Generally speaking, no. RHC is not allowed. There is, however, a small number of
cases where it is allowed. These are almost always cases where it is
impossible for any other option.

## User Scripts API

User Scripts are small code snippets that are usually supplied by the
user, intended for User Script managers like TamperMonkey and
Violentmonkey . It is not possible for these managers to bundle code that
is written by users, so the User Script API exposes a way to execute code
provided by the user. This is not a substitute for
chrome.scripting.executeScript , or other code execution environments.
Users must enable developer mode to execute anything. If the Chrome Web
Store review team thinks that this is being used in a manner other than it is
intended for (i.e. code provided by the user), it may be rejected or it's
listing taken down from the store.

## chrome.debugger

The chrome.debugger API gives extensions the ability to interact with
the Chrome Devtools Protocol . This is the same protocol that is used for
Chrome's Devtools, and an amazing number of other tools . With it, an
extension can request and execute remote code. Just like user scripts, it is not
a substitute for chrome.scripting, and has a much more notable user experience.
While it is being used, the user will see a warning bar at the top of the
window. If the banner is closed or dismissed, the debugging session will be
terminated.

Screenshot of the address bar in Chrome that has the message 'Debugger Extension started debugging this browser'

## Sandboxed iframes

If you need to evaluate a string as code, and are in a DOM environment (e.g. a
content script, as opposed to an extension service worker), then another option
is to use a sandboxed iframe . Extensions don't support things like
eval() by default as a safety precaution. Malicious code could put user safety
and security at risk. But when the code is only executed in a known safe
environment, like an iframe that has been sandboxed from the rest of the web,
then those risks are greatly reduced. Within this context, the Content Security
Policy that blocks the usage of eval can be lifted, allowing you to run any
valid JavaScript code.

If you have a use case that isn't covered, feel free to reach out to the team
using the chromium-extensions mailing list to get feedback, or open a new
ticket to request guidance from One Stop Support

## What to do if you disagree with a verdict

Enforcing policies can be nuanced and review involves manual input, which means
the Chrome Web Store team may sometimes agree to change a review decision. If
you believe that a mistake was made in review, you can appeal the rejection
using One Stop Support
