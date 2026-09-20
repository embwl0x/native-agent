<!-- url: https://developer.chrome.com/docs/webstore/program-policies/mv3-requirements -->
<!-- fetched: 2026-09-17 -->

-

Home

-

Docs

-

Chrome Extensions

-

Chrome Web Store - Program Policies

##
Additional Requirements for Manifest V3

Stay organized with collections

Save and categorize content based on your preferences.

assignment View single page version

- Extensions using Manifest V3 must meet additional requirements related to the extension's code. Specifically, the full functionality of an extension must be easily discernible from its submitted code, unless otherwise exempt as noted in Section 2. This means that the logic of how each extension operates should be self contained. The extension may reference and load data and other information sources that are external to the extension, but these external resources must not contain any logic. Some common violations include:

- Including a <script> tag that points to a resource that is not within the extension's package

- Using JavaScript's eval() method or other mechanisms to execute a string fetched from a remote source

- Building an interpreter to run complex commands fetched from a remote source, even if those commands are fetched as data

- Execution of logic from a remote source is permissible only when accomplished through a documented API that explicitly allows this practice and the use is inline with the documented purpose of the API, as detailed in the API Use policy . The permitted APIs for such remote execution are:

- Debugger API

- User Scripts API

Note that exemptions apply solely to the specific section of code covered by these APIs. Extensions may still be in violation of this policy if they employ alternative methods to execute logic from remote sources elsewhere in their code.

Additionally, code run in contexts that are isolated from extension APIs (such as iframes and sandboxed pages) are exempt from the restriction on loading code from remote sources; however, these are treated similarly to our policy on communication with external servers. That is, it must still be possible to determine the full functionality of your extension and the interaction must still comply with our user data policies, including Limited Use and the extension's Privacy Policy .

- Communicating with remote servers for certain purposes is still allowed. For instance:

- Syncing user account data with a remote server

- Fetching a remote configuration file for A/B testing or determining enabled features, where all logic for the functionality is contained within the extension package

- Fetching remote resources that are not used to evaluate logic, such as images

- Performing server-side operations with data (such as for the purposes of encryption with a private key)

- If we are unable to determine the full functionality of your extension during the review process, we may reject your submission or remove it from the store.
