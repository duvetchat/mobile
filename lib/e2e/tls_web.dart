/// The web build's: a browser tells a page no TLS failure apart, and package:http's BrowserClient makes every request
/// that got no answer a ClientException, which is the network's already.
library;

bool tlsFailed(Object error) => false;
