# Issue 273: make the release capture explicit

The enhanced runtime's Xcode 27 release build treats Swift diagnostics as
errors. Swift 6.4 rejects the exit-handler's `[weak self]` shorthand because
the enclosing lifecycle-lock closure also captures `self` implicitly and
strongly.

The handler must retain weak ownership while spelling out the captured value
as `[weak self = self]`. This is an ownership clarification only; it does not
change machine-exit behaviour or the stock Apple dependency path.

The defect was exposed by Container Compose Prebuilt Binaries run
`34961405310` after the matched-stack fail-fast checks passed.

Related issue: [#273](https://github.com/stephenlclarke/container/issues/273).
