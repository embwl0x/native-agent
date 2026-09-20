<!-- url: https://developer.chrome.com/docs/extensions/develop/migrate/improve-security -->
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
Improve extension security

Stay organized with collections

Save and categorize content based on your preferences.

Improving security in Manifest V3

This is the last of three sections describing changes needed for code that is not part of the extension service worker. It describes changes required to improve the security of extensions. The other two sections cover updating your code needed for upgrading to Manifest V3 and replacing blocking web requests .

## Remove execution of arbitrary strings

You can no longer execute external logic using executeScript() , eval() , and new Function() .

- Move all external code (JS, Wasm, CSS) into your extension bundle.

- Update script and style references to load resources from the extension bundle.

- Use chrome.runtime.getURL() to build resource URLs at runtime.

- Use a sandboxed iframe: eval and new Function(...) are still supported in sandboxed iframes. For more details read the guide on sandboxed iframes .

The executeScript() method is now in the scripting namespace rather than the tabs namespace. For information on updating calls, see Move executeScript() .

There are a few special cases in which executing arbitrary strings is still possible:

- Inject remote hosted stylesheets into a web page using insertCSS

- For extensions using chrome.devtools : inspectWindow.eval allows executing JavaScript in the context of the inspected page.

- Debugger extensions can use chrome.debugger.sendCommand to execute JavaScript in a debug target.

## Remove remotely hosted code

In Manifest V3, all of your extension's logic must be part of the extension package. You can no longer load and execute remotely hosted files according to Chrome Web Store policy . Examples include:

- JavaScript files pulled from the developer's server.

- Any library hosted on a CDN .

- Bundled third-party libraries that dynamically fetch remote hosted code.

Alternative approaches are available, depending on your use case and the reason for remote hosting. This section describes approaches to consider. If you are having issues with dealing with remote hosted code, we have guidance available .

## Configuration-driven features and logic

Your extension loads and caches a remote configuration (for example a JSON file) at runtime. The cached configuration determines which features are enabled.

## Externalized logic with a remote service

Your extension calls a remote web service. This lets you keep code private and change it as needed while avoiding the extra overhead of resubmitting to the Chrome Web Store.

## Embed remotely hosted code in a sandboxed iframe

Remotely hosted code is supported in sandboxed iframes . Please note that this approach does not work if the code requires access to the embedding page's DOM.

## Bundle third-party libraries

If you are using a popular framework such as React or Bootstrap that you were previously loading from an external server, you can download the minified files, add them to your project and import them locally. For example:

<script src="./react-dom.production.min.js"></script>
<link href="./bootstrap.min.css" rel="stylesheet">

To include a library in a service worker set the "background.type" key to "module" in the manifest and use an import statement.

## Use external libraries in tab-injected scripts

You can also load external libraries at runtime by adding them to the files array when calling scripting.executeScript() . You can still load data remotely at runtime.

chrome . scripting . executeScript ({
target : { tabId : tab . id },
files : [ 'jquery-min.js' , 'content-script.js' ]
});

## Inject a function

If you need more dynamism, the new func property in scripting.executeScript() allows you to inject a function as a content script and pass variables using the args property.

Manifest V2

let name = 'World!' ;
chrome . tabs . executeScript ({
code : `alert('Hello, ${ name } !')`
});
In a background script file.

Manifest V3

async function getCurrentTab () { /* ... */ }
let tab = await getCurrentTab ();

function showAlert ( givenName ) {
alert ( `Hello, ${ givenName } ` );
}

let name = 'World' ;
chrome . scripting . executeScript ({
target : { tabId : tab . id },
func : showAlert ,
args : [ name ],
});
In the background service worker.

The Chrome Extension Samples repo contains a function injection example you can step through. An example of getCurrentTab() is in the reference for that function.

## Look for other workarounds

If the previous approaches don’t help with your use case you might have to either find an alternative solution (i.e. migrate to a different library) or find other ways to use the library's functionality. For example, in the case of Google Analytics, you can switch to the Google measurement protocol instead of using the official remotely-hosted JavaScript version as described in our Google Analytics 4 guide .

## Update the content security policy

The "content_security_policy" has not been removed from the manifest.json file, but it is now a dictionary that supports two properties: "extension_pages" and "sandbox" .

Manifest V2

{
...
"content_security_policy" : "default-src 'self'"
...
}

Manifest V3

{
...
"content_security_policy" : {
"extension_pages" : "default-src 'self'" ,
"sandbox" : "..."
}
...
}

extension_pages : Refers to contexts in your extension, including html files and service workers.

sandbox : Refers to any sandboxed extension pages that your extension uses.

## Remove unsupported content security policies

Manifest V3 disallows certain content security policy values in the "extension_pages" field that were allowed in Manifest V2. Specifically Manifest V3 disallows those that allow remote code execution. The script-src, object-src , and worker-src directives may only have the following values:

- self

- none

- wasm-unsafe-eval

- Unpacked extensions only: any localhost source, ( http://localhost , http://127.0.0.1 , or any port on those domains)

Content security policy values for sandbox have no such new restrictions.
