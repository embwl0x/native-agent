<!-- url: https://developer.chrome.com/docs/extensions/develop/concepts/content-filtering -->
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
Content filtering

Stay organized with collections

Save and categorize content based on your preferences.

There are different ways to implement content and network filtering in Chrome Extensions. This guide provides an overview of content filtering capabilities available to extensions and the different filtering approaches, techniques and APIs that can be used by Chrome Extensions.

## Filter network requests

The primary way to filter network requests in Chrome Extensions is using the chrome.declarativeNetRequest API . With Declarative Net Request developers can block or modify network requests by specifying declarative rules. The Declarative Net Request rule format is based on the capabilities of the filter list syntax used by most ad blockers.

These rules are able to:

- Block a network request.

- Upgrade the URL scheme to a secure scheme (http to https or ws to wss).

- Redirect a network request.

- Modify request or response headers.

Chrome supports rules bundled with an extension, and those updated dynamically (such as in response to a remote config or user input).

## Bundle filter rules with your extension

Rules included in your extension package are called "static rules". These rules are installed and updated when an extension is installed or upgraded. Chrome limits how many static rules an extension can declare.

For static Declarative Net Request rules, Chrome has a global shared pool of 300,000 rules that can be used jointly by the set of installed extensions. In addition, every extension is guaranteed an allowance of 30000 static rules. For example, if a user has only a single content filtering extension installed, the extension can use up to 330,000 static Declarative Net Request rules. To get an idea of how many rules this is, the popular EasyList filter list , used by most ad blockers, consists of around 35,000 network rules.

Static Declarative Net Request rules can be organized into different rulesets. An extension can specify up to 100 static rulesets, and 50 of these rulesets can be enabled at a time.

## Dynamically add filter rules at runtime

Some rules cannot be bundled with the extension. Instead, extensions need to add them at runtime. These rules are called "dynamic rules".

For dynamic Declarative Net Request rules, Chrome allows a maximum of 30,000 safe dynamic rules per extension. Most rules are considered safe rules: block , allow , allowAllRequests or upgradeScheme . Even if a rule is not considered safe (for example redirect ), they can still be added dynamically, but with a lower maximum limit of 5,000 which also counts towards the 30,000 dynamic rules limit. To set this into perspective, 98-99% of rules in the easylist filter list are safe rules .

Content filtering extensions can use static and dynamic rules respectively to bundle known filtering rules with their extension and to update their extensions with new content filtering rules from their servers whenever needed.

## Adapt rules based on observed requests

The ad ecosystem is constantly evolving and content filters need to be updated accordingly. By combining chrome.webRequest and dynamic Declarative Net Request rules it is possible to analyze network requests for potential privacy violations and block these in the future.

The basic approach is:

- Analyze web requests using the chrome.webRequest API and try to automatically identify requests that don't meet your privacy requirements, for example, using machine learning.

- Create a dynamic Declarative Net Request rule for each request that has been identified in step two so that similar requests will be blocked in the future.

- (Optional) Send the identified Declarative Net Request rule back to your server so that it can be added as a static Declarative Net Request rule with your next extension update.

The benefit of this approach is that the analysis happens asynchronously and won't negatively affect website performance.

## Allow users to define their own filtering rules

You can let your users define their own content filtering rules by providing a filter configuration UI in your extension. Convert these user defined rules into Declarative Net Request rules and add them as dynamic rules . These rules will continue to be available for users as they persist across browser sessions and extension upgrades. Using this approach, users can add up to 30,000 custom rules.

## Filter elements on web pages

Filtering network requests is only one important part of content filtering. Another big part is removing unwanted content directly from web pages. For example, more than 40% of easylist filter list rules define how clients should hide page elements.

This can be achieved using content scripts . Content scripts run in the context of web pages and can make changes to them using the DOM.

Chrome Extensions are not allowed to execute remote hosted code . However, data from a server about which elements to hide are not impacted as this is considered configuration data, hence, element rules can be updated at runtime whenever necessary.

## Filter network requests in policy installed extensions

Enterprise and education use cases often have extremely strict requirements for content and network filtering, such as filtering requests based on their content. To enable these use cases, policy installed extensions have an additional way to filter and block network requests. Using the "blocking" option with events in the webRequest API, it is possible to implement a programmatic content filter that executes custom logic on every request to decide whether a request should be blocked or not. This is restricted to policy-installed extensions as these have a higher level of trust.

## Intercept navigation requests

Navigation requests can be filtered using Declarative Net Request rules. For example, you may want to bypass tracking URLs that redirect the user to their intended destination. One approach to handle this is to redirect a navigation request https://tracker.com?redirect=https%3A%2F%2Fexample.com to an extension page (which needs to be configured as a web accessible resource ), which will then run a script to extract the redirect target and redirect to the destination using window.location.replace("https://example.com") circumventing the link tracker.
