# DataStore3

DataStore3 (DS3) is the DataStore model used by me, which I've decided to *casually* share up as a simple library. I get the feeling that this approach to DataStores has been done many times before, so I take no credit as the creator of this approach.

Specifics on how to use DS3 are explained in a large comment at the top of DataStore3.lua.

It follows some specific design goals:
* Simplicity in use
* Minimal bloat
* Easy to modify, read, and install
* Minimal necessary interaction with DS3
* Data to be saved cannot be out of date

Covers the basics:
[x] Autosaves
[x] Binds to close
[x] Built-in caching of data
[x] Uses a master key
[x] Table validation
[x] Temporary non-saving stores if a `get` fails

**WARNING**: The size of the stored table is not checked to be less than the current maximum size. The resulting DataStore error will be logged to the server console, but goes unhandled! Handling the error transparently would add a lot of complexity to the design of the module, which, in *most* use cases, is never necessary.

Unfortunately I have not written any tests for this module, but its simplicity makes its failure points scarce. It has served me well in developing backends for various projects.