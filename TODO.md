- [x] tabs are displayed two times when started as emacsclient
- [x] marked tabs are not restored when started as emacsclient
- [ ] Ctrl+s: prompt disappears after short time
- [ ] Pick > File stopped working when run as `emacs -nw`: Invalid `parent-frame` frame parameter. Works when run with `emacsclient -t -a ""`
- [x] CHAR and Extend and left - cannot go left
- [x] CHAR and Extend and left - cannot go right
- [ ] when emacs started with `emacsclient -t -a ""` and close with `C-x c` and emacsclient started again, it using ok. But when closed with `Space j q` and emacsclient started again, it looks like emacs daemon is starting again like it was killed by `Space j k`.
- [ ] go up with WORD, SUBWORD, CHAR etc. should take into account wrapped lines, so go to up line visually. Same with down.
- [ ] change how navigation with NODE works. Right now up goes parent node, down goes child node. It should be like that: up goes to deepest node that is visually above current node, so take into account wrapped lines. To go parent down, there should be NODE momentary layer: `d i` goes to parent node, `d k` goes to child node. There could be some interesting operations for `n j` and `n l` but it needs to be figured out.
- [ ] sometimes when started emacsclient, tabs look like this:

```
 [-] init.el  [-] ri.el
|ri.el x|init.el<emacs> x| +
```
