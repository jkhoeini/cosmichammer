### To write docs

1. Lua and Objective-C docstrings start with `---` or `///` at the beginning of a line.
2. Swift docstrings start with `///`, optionally after leading whitespace.
3. Docstrings continue until a non-docstring line or EOF.
4. Module docstrings contain `=== my.modulename ===`, then any number of lines describing the module.
5. Item docstrings for functions, variables, constants, and methods go like this:
   1. The first line starts with `my.modulename.item` or `my.modulename:item` -- this is the item name
   2. Any non-alphanumeric character ends the item name and is ignored, i.e. parentheses or spaces:
      1. `my.modulename:foo()`
      2. `my.modulename:foo(bar) -> string`
      3. `my.modulename.foo(bar, fn(int) -> int)`
      4. `my.modulename.foo = {}`
   3. The second line is a single capitalized word, like "Variable" or "Function" or "Method" or "Constant" or "Field"
   4. The remaining lines describe the item
6. Any comment that starts with 4 comment characters is ignored.
7. Swift `///` chunks are emitted only when the first doc line starts with `===` or `hs.`.
8. Only files ending in `.lua`, `.m`, or `.swift` are scanned.

### To generate docs

~~~bash
$ swift build -c release --package-path scripts/docs
$ just docs
~~~

`just docs` writes JSON, Markdown, HTML, and SQLite output under `build/`.
`just docs-lint` validates docstrings without writing full docs.

### To test the docs tool

~~~bash
$ swift test --package-path scripts/docs
~~~
