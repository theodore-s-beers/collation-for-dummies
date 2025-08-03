---
title: "Unicode Collation for Dummies"
author: "Theodore Beers"
date: "14 July 2025"
---

This post is meant as an introduction to the
[Unicode Collation Algorithm](https://www.unicode.org/reports/tr10/) (UCA), a
standardized solution to a problem that turns out to be surprisingly complex:
how can we alphabetically sort items of text when the characters go beyond the
basic Latin alphabet? Let's find out...

_Sidebar: I maintain a simple but conformant & performant implementation of the
UCA in Rust, called
[feruca](https://github.com/theodore-s-beers/feruca)&VeryThinSpace;; and I
recently adapted it to Zig, in a library called
[later](https://github.com/theodore-s-beers/later)&VeryThinSpace;. Code examples
in this post will be in Zig. You may also like to visit my
"[Text Sorting Playground](https://www.theobeers.com/allsorts/)&VeryThinSpace;,"
a little web app that demonstrates the differences among a few approaches to
collation._

## Introduction

Given two strings of UTF-8-endoded text---let's say, for example, the names
"Edgar" and "Frank"---it is trivial for a computer to determine which of them
should come first alphabetically. If we look at a representation of those
strings as arrays of byte values, we find that "Edgar" is (in hexadecimal)
`[45, 64, 67, 61, 72]`; and "Frank" is `[46, 72, 61, 6E, 6B]`. Simple array
comparison yields a difference at index 0, with E being "less than" F, so that
Edgar sorts before Frank. This is a happy consequence of the fact that early
text encoding schemes---notably ASCII, which was inherited by Unicode---assigned
numerical values to the letters that they included in _a kind of_ alphabetical
order. There is still the issue that ASCII groups all the uppercase letters
before all the lowercase letters, so that, for example, "earnest" will sort
after "Frank." But at least we have an alphabetical order of byte values within
the uppercase and lowercase groups.

Back to the larger problem: what happens if we add, say, "Élodie" to our list of
names? A human will understand intuitively that E and É belong together as
variants of the same letter---perhaps with the accented version to come after
the unaccented, alphabetically. But how can we establish this rigorously in a
way that facilitates automated sorting? The letter É has two main
representations in Unicode: either as a single character, `U+00C9`, for a Latin
capital E with an acute accent; or as a combination of two characters, `U+0045`
and `U+0301`, accounting for the base letter and the accent, respectively. (I
wanted to bring up the "decomposed representation" as early as possible in this
post, since it is the form that we generally want for Unicode sorting/collation.
More on this later...)

Both of these representations will break the naïve approach to sorting, in their
own ways. `C9` as a byte value is greater than any in the ASCII/Basic Latin
table, meaning that "Élodie" would sort after, say, "Zoë." Using the decomposed
form seems promising---the first byte value is simply that of E, appropriate for
sorting---but the combining accent character introduces new problems. `0x301` is
too large to be represented in a single byte, so in UTF-8 it becomes `[CC, 81]`.
"Élodie" in decomposed form is made up of seven code points, in eight bytes in
the common encoding, where we perceive only six letters. It should be obvious
how this would wreak havoc on a sorting algorithm that does nothing more than
array comparison on the byte values.

We need something better. Unicode is a large and complex system, and if we want
a way of mapping code points to collation weights, it will have to be defined
explicitly. That's where the Unicode Collation Algorithm comes in.

Testing Zig syntax highlighting:

```zig
test "sort multilingual list of names" {
    const alloc = std.testing.allocator;

    var coll = try Collator.initDefault(alloc);
    defer coll.deinit();

    var input = [_][]const u8{
        "چنگیز",
        "Éloi",
        "Ötzi",
        "Melissa",
        "صدام",
        "Mélissa",
        "Overton",
        "Elrond",
    };

    const expected = [_][]const u8{
        "Éloi",
        "Elrond",
        "Melissa",
        "Mélissa",
        "Ötzi",
        "Overton",
        "چنگیز",
        "صدام",
    };

    std.mem.sort([]const u8, &input, &coll, collateComparator);
    try std.testing.expectEqualSlices([]const u8, &expected, &input);
}
```
