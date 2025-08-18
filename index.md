---
title: "Unicode Collation for Dummies"
author: "Theodore Beers"
date: "August 2025"
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

## Table of Contents

- [Introduction](#introduction)
- [Basic Idea](#basic-idea)
- [Simple but Real Examples](#simple-but-real-examples)
- [The Plot Thickens](#the-plot-thickens)
- [From UTF-8 to Code Points](#from-utf-8-to-code-points)
- [NFD Normalization](#nfd-normalization)
- [Prefix Trimming](#prefix-trimming)
- [The Collation Element Array](#the-collation-element-array)
- [Sort Keys](#sort-keys)
- [Performance Optimization](#performance-optimization)
- [What About Tailoring?](#what-about-tailoring)

## Introduction

Given two strings of UTF-8-encoded text---let's say, for example, the names
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

```default
Edgar
Frank
Zardoz
earnest # Not ideal
```

Back to the larger problem: what happens if we add, say, "Élodie" to our list of
names? A human will understand intuitively that E and É belong together as
variants of the same letter---perhaps with the accented version to come after
the unaccented, alphabetically. But how can we establish this rigorously in a
way that facilitates automated sorting? The letter É has two main
representations in Unicode: either as a single character, `U+00C9`, for a Latin
capital E with an acute accent; or as a combination of two characters, `U+0045`
and `U+0301`, accounting for the base letter and the accent, respectively. (I
wanted to bring up the "decomposed representation" as early as possible in this
post, since it's the form that we generally want for Unicode sorting/collation.
More on this later...)

Both of these representations will break the naïve approach to sorting, in their
own ways. `C9` as a byte value is greater than any in the ASCII/Basic Latin
table, meaning that "Élodie" would sort after, say, "Zardoz." Using the
decomposed form seems promising---the first byte value is simply that of E,
appropriate for sorting---but the combining accent character introduces new
problems. `0x301` is too large to be represented in a single byte, so in UTF-8
it becomes `[CC, 81]`. "Élodie" in decomposed form is made up of seven code
points, in eight bytes in the common encoding, where we perceive only six
letters. It should be obvious how this would wreak havoc on a sorting algorithm
that does nothing more than array comparison on the byte values.

```default
Edgar
Zardoz
earnest
Élodie  # Assuming form NFC
```

**We need something better.** Unicode is a large and complex system, and if we
want a way of mapping code points to collation weights, it will have to be
defined explicitly. That's where the Unicode Collation Algorithm comes in.

## Basic Idea

_Some of what follows is oversimplification. If you're already familiar with
this subject, please try to be charitable. I'll go into greater detail as the
post progresses._

The central concept of Unicode collation is that one character might belong
before/after another character on different bases. They may represent
fundamentally different letters, like E and F; they may be different forms of
something understood to be the "same" letter, like E and É; or they may be
closer still, differing only in case, like E and e. Of course, languages and
writing systems are extremely diverse, and not all of them even have a concept
of uppercase vs. lowercase. But it turns out that allowing for a hierarchy of
three (or sometimes four) levels of collation difference between code points is
generally sufficient to get the job done.

In a writing system like the Latin alphabet, these levels are indeed organized
as I hinted above: the _primary_ level of collation distinguishes among
different base letters; the _secondary_ level distinguishes among diacritics,
like accents; and the _tertiary_ level accounts for case differences. If we
assign to each code point in the Unicode tables a set of primary, secondary, and
tertiary _collation weights_, we can then decide which of them sorts before the
other by comparing their weights one level at a time. And this can be
extrapolated to collate entire strings.

Let's look at some real examples from the **Default Unicode Collation Element
Table** ([DUCET](https://www.unicode.org/Public/UCA/latest/allkeys.txt)), one of
the standard documents that Unicode publishes in order to make this possible.
NB, the following lines are not necessarily adjacent in the original; I'm
pulling examples from different areas.

```default
0301  ; [.0000.0024.0002]                  # COMBINING ACUTE ACCENT
0045  ; [.23E7.0020.0008]                  # LATIN CAPITAL LETTER E
00C9  ; [.23E7.0020.0008][.0000.0024.0002] # LATIN CAPITAL LETTER E WITH ACUTE
0058  ; [.2660.0020.0008]                  # LATIN CAPITAL LETTER X
1D54F ; [.2660.0020.000B]                  # MATHEMATICAL DOUBLE-STRUCK CAPITAL X
007A  ; [.2682.0020.0002]                  # LATIN SMALL LETTER Z
0642  ; [.2AF9.0020.0002]                  # ARABIC LETTER QAF
```

What we find in each line is the code point; a semicolon separator; one or more
_sets of weights_, each consisting of primary, secondary, and tertiary parts;
and a comment giving the official name of the Unicode scalar value. _All
numerical values are in hexadecimal._ We can look at one in greater detail:

```default
0058  ; [.2660.0020.0008] # LATIN CAPITAL LETTER X
^         ^    ^    ^       ^
cp        p    s    t       name
```

Hopefully you can see already where this is going. If we want to determine the
proper lexicographical order of two characters---to take the simplest scenario
possible---we can find their collation weights and compare them at the primary,
then the secondary, then the tertiary level, returning as soon as we find a
difference. Look, for example, at the respective weights of an ordinary capital
letter X and the "mathematical double-struck capital X," i.e., the logo of the
site formerly known as Twitter. They differ only at the tertiary level: both
belong to the X family, and neither has a diacritic.

```default
0058  ; [.2660.0020.0008] # LATIN CAPITAL LETTER X
1D54F ; [.2660.0020.000B] # MATHEMATICAL DOUBLE-STRUCK CAPITAL X
```

The reality of Unicode collation ends up being significantly more complex than
this, but we can start on the happy path.

## Simple but Real Examples

### Élodie and Frank

Armed with our fledgling understanding of how the Unicode Collation Algorithm
works, let's return to the test case of placing the names "Élodie" and "Frank"
in alphabetical order. We'll begin by representing them as arrays of code
points, each of which has its assigned collation weights in the standard table.

First, Élodie (note that we use the _decomposed_ form of É; this is a crucial
part of the UCA):

```default
0045  ; [.23E7.0020.0008] # LATIN CAPITAL LETTER E
0301  ; [.0000.0024.0002] # COMBINING ACUTE ACCENT
006C  ; [.24BC.0020.0002] # LATIN SMALL LETTER L
006F  ; [.252C.0020.0002] # LATIN SMALL LETTER O
0064  ; [.23CA.0020.0002] # LATIN SMALL LETTER D
0069  ; [.2473.0020.0002] # LATIN SMALL LETTER I
0065  ; [.23E7.0020.0002] # LATIN SMALL LETTER E
```

Next, Frank:

```default
0046  ; [.2422.0020.0008] # LATIN CAPITAL LETTER F
0072  ; [.2584.0020.0002] # LATIN SMALL LETTER R
0061  ; [.2380.0020.0002] # LATIN SMALL LETTER A
006E  ; [.2505.0020.0002] # LATIN SMALL LETTER N
006B  ; [.24A8.0020.0002] # LATIN SMALL LETTER K
```

Since the first round of collation checking will be on the primary weights of
these two words, we can pull those out and make a simpler array of primaries for
each word, called a _sort key_.

It's important to note that _only nonzero weights_ are considered here. As you
can see, the "combining acute accent" character has no primary weight. We ignore
that zero when constructing the sort key. This is necessary so that, for
example, two words like "Maria" and "María," which differ only by an accent, are
_identical_ at the primary level. Allowing a zero primary weight for an accent
character to enter the sort key would immediately break collation. Anyway, our
primary-level sort keys for "Élodie" and "Frank" are as follows:

```default
[23E7, 24BC, 252C, 23CA, 2473, 23E7] # Élodie
[2422, 2584, 2380, 2505, 24A8]       # Frank
```

You don't have to be a genius to figure this out. We're back to straightforward
array comparison, and we can reach a decision at index 0: "Élodie" belongs
first.

### Élodie and Elodie

Now for a bit of a contrived example: what if we also had the name "Elodie"
without the accent? How would collation proceed? We already know what the
primary-level sort key would be for both words:

```default
[23E7, 24BC, 252C, 23CA, 2473, 23E7] # Élodie or Elodie (primary)
```

That is, comparison at the primary level would yield no difference. We then move
to the secondary level, again building sort keys out of all nonzero weights:

```default
[0020, 0024, 0020, 0020, 0020, 0020, 0020] # Élodie (secondary)
[0020, 0020, 0020, 0020, 0020, 0020]       # Elodie (secondary)
```

Now we see that "Élodie" has an extra element in its list of secondary weights,
and it is higher than the others. We reach a decision at index 1 in the
secondary sort key: "Elodie" (sans accent) belongs first.

### Frank and frank

For the sake of thoroughness, let's also consider two words that differ only in
case, i.e., at the tertiary level. The name "Frank" and the common adjective
"frank" will work nicely for this. We can add to the previous list of weights
the values for lowercase f:

```default
0066  ; [.2422.0020.0002] # LATIN SMALL LETTER F
0046  ; [.2422.0020.0008] # LATIN CAPITAL LETTER F
0072  ; [.2584.0020.0002] # LATIN SMALL LETTER R
0061  ; [.2380.0020.0002] # LATIN SMALL LETTER A
006E  ; [.2505.0020.0002] # LATIN SMALL LETTER N
006B  ; [.24A8.0020.0002] # LATIN SMALL LETTER K
```

The primary-level sort key will not yield a difference:

```default
[2422, 2584, 2380, 2505, 24A8] # Frank or frank (primary)
```

Nor will the secondary-level sort key:

```default
[0020, 0020, 0020, 0020, 0020] # Frank or frank (secondary)
```

But we finally have something at the tertiary level:

```default
[0008, 0002, 0002, 0002, 0002] # Frank (tertiary)
[0002, 0002, 0002, 0002, 0002] # frank (tertiary)
```

At index 0 in the tertiary sort key, we see that "frank" belongs first.

_This is a noteworthy difference between the Unicode Collation Algorithm and
ASCII sorting: the order of the cases is reversed! An implementation of the UCA
can of course make this configurable; it's trivial to set a flag and have
comparisons reversed at the tertiary level. But the difference in default
behavior is interesting nonetheless._

## The Plot Thickens

Some readers may like to stop here. I've given you enough of a primer that you
could explain the general idea behind Unicode collation and how it works. You
could even, with reference to a copy of `allkeys.txt` (i.e., the DUCET file),
perform manual collation of one string against another. That should be more than
enough to impress someone at a cocktail party.

But I want to go on and show, in greater detail, what is actually involved in
writing a conformant implementation of the UCA---i.e., an implementation that
passes the punishingly rigorous
[conformance tests](https://www.unicode.org/Public/UCA/latest/CollationTest.html)
that are published alongside the technical standard. So if you're interested in
digging deeper, feel free to stick around and keep reading.

I think it will be helpful for most of the remainder of this post to be guided
by the actual code of the collation routine that I wrote for my Zig library,
[later](https://github.com/theodore-s-beers/later). This comes from
`src/collator.zig`:

```zig
pub fn collateFallible(self: *Collator, a: []const u8, b: []const u8) !std.math.Order {
    if (std.mem.eql(u8, a, b)) return .eq;

    try decode.bytesToCodepoints(&self.a_chars, a);
    try decode.bytesToCodepoints(&self.b_chars, b);

    // ASCII fast path
    if (ascii.tryAscii(self.a_chars.items, self.b_chars.items)) |ord| return ord;

    try normalize.makeNFD(self, &self.a_chars);
    try normalize.makeNFD(self, &self.b_chars);

    const offset = try prefix.findOffset(self); // Default 0

    // Prefix trimming may reveal that one list is a prefix of the other
    if (self.a_chars.items[offset..].len == 0 or self.b_chars.items[offset..].len == 0) {
        return util.cmp(usize, self.a_chars.items.len, self.b_chars.items.len);
    }

    try cea.generateCEA(self, offset, false); // a
    try cea.generateCEA(self, offset, true); // b

    const ord = sort_key.cmpIncremental(self.a_cea.items, self.b_cea.items, self.shifting);
    if (ord == .eq and self.tiebreak) return util.cmpArray(u8, a, b);

    return ord;
}
```

This can be broken down into eight steps, some of them quite simple, others
horrifyingly complex:

1. Handle edge cases (i.e., equal is equal and returns immediately).

2. Ensure that the input strings are valid UTF-8 (applying fixes if needed), and
   decode from bytes to Unicode scalar values.

3. See if a result can be reached by comparing ASCII-range characters in the two
   strings; this is often not possible, but when it is, it saves so much
   computation that it's an indispensable code path.

4. If we need to continue with the UCA proper, begin by ensuring that both
   strings have all their characters in the canonical decomposed form, i.e.,
   [NFD](https://en.wikipedia.org/wiki/Unicode_equivalence#Normalization).

5. Check if the two strings have a prefix in common that can safely be ignored
   in collation. Doing this while conforming to the standard is more difficult
   than it seems, for reasons that I may not even be able to cover in this post.
   Prefix trimming can sometimes produce a collation result on its own, if one
   string turns out to be a prefix of the other.

6. Generate the _collation element array_. This process is by far the most
   complex part of the UCA. It corresponds to the step shown above (in a very
   basic case), where we looked up the collation weights associated with each
   code point in each of the strings being compared. There are many subtleties
   to consider here; I'll get into it below.

7. Process the collation element arrays into _sort keys_, checking one level at
   a time until a result is yielded. By this point, most of the hard work has
   been done.

8. If the sort keys somehow came back identical, there is a final option to use
   naïve comparison of the input strings as a tiebreaker.

We can look at these steps one-by-one---at least, in those cases where there's
anything worth saying. One fun part of implementing the UCA in Zig was that I
chose not to use any dependencies outside of the standard library. So I dealt
with problems like UTF-8 validation and decoding and NFD normalization in my own
code. I'll show snippets of how these components work. Still, the main focus
will be on the core logic of the UCA.

## From UTF-8 to Code Points

I don't have a lot to say here, since UTF-8 validation/decoding is a
well-understood problem with many solutions available in the public domain. The
one that I chose to adapt to Zig, however, is probably one of the most elegant
pieces of code I've ever seen. It's a famous UTF-8 decoder written in C by Björn
Höhrmann, subsequently improved by Rich Felker (creator/maintainer of musl).

This decoder is based on a deterministic finite automaton, i.e., a state
machine, wherein each byte of UTF-8 that is encountered causes a certain state
transition. There is a "home state," or an "accept state," which is reached each
time that a full code point has been processed. This can happen, of course,
after anything from one to four bytes.

Any invalid sequence brings the DFA into a "reject state," which is normally
handled by having the decoder emit the "Unicode replacement character,"
`U+FFFD`. What I find brilliant, though, is that validation of UTF-8 sequences
is accomplished hand-in-hand with determining the code points. That is, each
time that the DFA reaches the "accept state," the function also has access to
the value of the code point that has just been completed. For a case like
Unicode normalization, this is perfect: what we want for the algorithm is a list
of code points in `u32` (or `u21`, but you get the idea). Below you can see what
I mean; I've added some comments for clarity. This comes from `src/decode.zig`:

```zig
pub fn bytesToCodepoints(codepoints: *std.ArrayList(u32), input: []const u8) !void {
   // For performance reasons, we keep reusing a list of code points
   codepoints.clearRetainingCapacity();
   try codepoints.ensureTotalCapacity(input.len);

   // Start with the "accept state" and 0 code point value
   var state: u8 = UTF8_ACCEPT;
   var codepoint: u32 = 0;

   // Iterate over bytes of the string
   for (input) |b| {
      // Get the next state and updated code point value
      const new_state = decode(&state, &codepoint, b);

      // If we reached an "end state," handle it
      if (new_state == UTF8_REJECT) {
         codepoints.appendAssumeCapacity(REPLACEMENT);
         state = UTF8_ACCEPT;
      } else if (new_state == UTF8_ACCEPT) {
         codepoints.appendAssumeCapacity(codepoint);
      }

      // Otherwise continue to the next byte (of a multi-byte character)
   }

   // If we ended in an incomplete sequence, emit replacement
   if (state != UTF8_ACCEPT) codepoints.appendAssumeCapacity(REPLACEMENT);
}
```

I've left out the `decode` function, but you can look into this further if
you're curious and haven't seen an implementation of this style of UTF-8 decoder
before. The basic idea is that each byte from the input string is treated as an
index into a table in order to compute the next state and value of the code
point variable.

Fortunately, this is also quite performant! It's _not_ the fastest possible
approach. Daniel Lemire has written a few blog posts
([example](https://lemire.me/blog/2018/05/09/how-quickly-can-you-check-that-a-string-is-valid-unicode-utf-8/)),
and at least one academic paper, on the subject of maximizing performance in
UTF-8 validation/decoding. But Höhrmann's decoder continues to be popular
because it's good enough, easy to understand, and elegant. Everyone should give
it a try at some point.

## NFD Normalization

As I mentioned earlier, Unicode collation requires that the characters in each
string be _decomposed_ and _in canonical order_. This means that any code point
that is considered (per the Unicode standard) to be a composition of multiple
other, lower-level code points must be broken down into those. I gave a simple
example: "É," the Latin-script capital E with an acute accent. This letter can
be, and most often is, represented by the single code point `U+00C9`. In fact,
the great majority of digital text that we encounter these days is in the UTF-8
encoding and in form NFC, i.e., with characters _composed_ into shorter
representations where possible, and upholding _canonical equivalence_. (That is,
characters that are considered equivalent are guaranteed to be represented the
same way in form NFC.)

Back to "É," though: it can also be represented via two code points, `U+0045`
for the capital letter E, and `U+0301` for the combining acute accent. This is
another canonical Unicode form, called NFD. I'm sure you get the idea, at least
in a basic sense. Whereas NFC has composed characters, NFD has them decomposed
and with the constituent parts in a standard order. You can perhaps also
understand how this is helpful---necessary, in fact---for proper sorting.
Breaking down "É" into "E followed by an acute accent" is what allowed us to
derive identical sort keys for "Élodie" and "Elodie" at the primary level, and
for the accent to make the collation decision between the two words at just the
right spot (i.e., just after the initial letter/index).

I worry this discussion could become dense, but on some level it should be
straightforward enough. We deal with mostly NFC text data in the wild, and we
need to convert to NFD to apply the Unicode Collation Algorithm. How can we do
that? It ends up being one of those problems that teaches you a lot about the
Unicode standard if you want to write your own implementation. This is because
you need to be able to determine, for any code point, what its canonical
decomposition is (if any); and how those decomposed parts must be ordered. I
tried to keep this understandable in my code, with a high-level function that
goes through the different steps of the NFD conversion process. This comes from
`src/normalize.zig`:

```zig
pub fn makeNFD(coll: *Collator, input: *std.ArrayList(u32)) !void {
   if (try fcd(coll, input.items)) return;

   try decompose(coll, input);
   reorder(input.items);
}
```

As you can see, we have a short `makeNFD` function that does three things.
First, it checks whether the input meets certain criteria that obviate the need
for any decomposition. (FCD is short for "fast NFC/NFD.") We can set aside the
details of this part for the time being. Second, in case NFD conversion _is_
needed, we decompose the input code points. Finally, we ensure that the
decomposed code points are in their canonical ordering.

Sounds easy, doesn't it? But let's have a look at the `decompose` function. I've
added comments for clarity.

```zig
fn decompose(coll: *Collator, input: *std.ArrayList(u32)) !void {
   var i: usize = 0;

   // We need to manage i manually in this loop
   while (i < input.items.len) {
      const code_point = input.items[i];

      // Code points below a certain value never require decomposition
      if (code_point < 0xC0) {
         i += 1;
         continue;
      }

      // Certain Korean text requires special handling; don't ask
      if (0xAC00 <= code_point and code_point <= 0xD7A3) {
         const len, const arr = decomposeJamo(code_point);
         try input.replaceRange(i, 1, arr[0..len]);

         i += len;
         continue;
      }

      // If a canonical decomposition exists for this code point, apply it
      if (try coll.getDecomp(code_point)) |decomp| {
         try input.replaceRange(i, 1, decomp);
         i += decomp.len;
         continue;
      }

      i += 1;
   }
}
```

The only trick here, apart from the weird Korean stuff, is that we need an
efficient way of fetching the canonical decomposition (if any) of a given code
point. I did this in a naïve but functional way, by building a hash table from
Unicode data. All that my `getDecomp` function does is to check in that table.
(The crazier part is that is that I have a bunch of data structures like this
that are derived from Unicode data, and for performance reasons I have them
serialized in binary formats. These maps are in some cases large, up to a few
hundred KiB on disk, but they can be loaded rapidly at runtime, and a given
collator instance needs to do so only once.)

Once decomposition has been accomplished, all that's left for NFD is to fix the
order of the code points so that it matches what is expected canonically in the
Unicode standard. This is governed by a property called "canonical combining
class." In the case of what we might refer to as _base letters_, the combining
class is 0, i.e., "not reordered." Such code points are never moved in
normalization. Diacritics, on the other hand, have a variety of nonzero
combining class values; and when they appear next to one another in a sequence,
they should be in order of ascending combining class. The most common scenario
in which this might become an issue is when a letter has two or more diacritics
attached to it. I can say from my own academic background that this happens with
some frequency in Arabic text. There is, for example, a diacritic called
_shadda_, which serves to add emphasis to a consonant; and there are other
diacritics that serve as short vowel marks. It is by no means uncommon to see an
Arabic letter that has both a _shadda_ and a vowel mark above it. In such cases,
the base letter would have a combining class of 0, and the multiple diacritics
should, ideally, be set in order of ascending combining class. Let's look at an
example:

```default
U+0628 # Arabic letter bā’, CCC 0
U+064E # Arabic vowel fatḥa, CCC 30
U+0651 # Arabic shadda, CCC 33
```

The above sequence meets the criteria of form NFD. Note that it is _entirely
conceivable_ that someone might type the _shadda_ before the _fatḥa_; I do so
myself. In that case, reordering would be needed for NFD to be achieved, and by
extension for Unicode collation.

The last thing that I'll show here is my `reorder` function, mostly because it
takes the form of a modified bubble sort, which amuses me. In my several years
of work as a programmer, this is the only context in which I've been compelled
to use everyone's favorite inefficient sorting algorithm. Comments are added for
clarity.

```zig
fn reorder(input: []u32) void {
   var n = input.len;

   while (n > 1) {
      var new_n: usize = 0;
      var i: usize = 1;

      // We compare two code points at a time
      while (i < n) {
         const cc_b = ccc.getCombiningClass(input[i]);

         // If the second code point has CCC 0, we can advance by 2
         if (cc_b == 0) {
            i += 2;
            continue;
         }

         const cc_a = ccc.getCombiningClass(input[i - 1]);

         // The first code point should have CCC 0 or <= cc_b
         if (cc_a == 0 or cc_a <= cc_b) {
            i += 1;
            continue;
         }

         // This means the check failed, and a swap is needed
         std.mem.swap(u32, &input[i - 1], &input[i]);

         // We use a small optimization to avoid rechecking sorted ranges
         new_n = i;
         i += 1;
      }

      n = new_n;
   }
}
```

As you can see, this relies on repeated calls of `getCombiningClass`. I found,
while benchmarking my UCA implementation, that looking up combining classes is
one of the hottest paths in the entire library. It demands a special degree of
optimization, which is an interesting problem but beyond the scope of this post.

## Prefix Trimming

This sounds like it should be one of the simplest steps in the collation
process. By this point, we know that the two strings being compared are not
equal, and that a collation decision cannot be reached by looking at ASCII-range
characters at the beginning of each string. And both have been set in form NFD
(or close enough, via FCD). Now we can just trim whatever common prefix exists
in the two lists of code points, n'est-ce pas? Almost, but there are a few
subtleties of Unicode collation that can trip us up.

Let's have a look at my `findOffset` function. Note that, for performance
reasons, it's better to avoid actually removing any shared prefix code points
from the two lists. We instead find the appropriate offset and _ignore_ the
prefix. I've added comments to the following code for clarity; even so, it will
need some explanation. This is from `src/prefix.zig`:

```zig
pub fn findOffset(coll: *Collator) !usize {
   const a = coll.a_chars.items;
   const b = coll.b_chars.items;
   var offset: usize = 0;

   while (offset < @min(a.len, b.len)) : (offset += 1) {
      // Obviously, we stop incrementing the offset once the lists differ
      if (a[offset] != b[offset]) break;

      // If we reach a character that could begin a multi-code-point sequence
      // in the collation tables, we also stop
      if (std.mem.indexOfScalar(u32, &consts.NEED_TWO, a[offset])) |_| break;
      if (std.mem.indexOfScalar(u32, &consts.NEED_THREE, a[offset])) |_| break;
   }

   if (offset == 0) return 0;

   // If we're using the "shifted" approach to variable-weight characters,
   // and the last character in the prefix is one such, we have a problem
   if (coll.shifting and try coll.getVariable(a[offset - 1])) {
      // We can try walking the offset back by one
      if (offset > 1) {
         if (try coll.getVariable(a[offset - 2])) return 0;
         return offset - 1;
      }

      // On rare occasions (i.e., in the conformance tests), this might fail
      // the entire prefix function
      return 0;
   }

   return offset;
}
```

I'm sure that neither of the problem scenarios makes any sense right now, but
I'll explain what's going on. You can see already that we have to keep an eye
out for two things in the prefix code points: characters that may begin
multi-code-point sequences in the collation tables (and therefore cannot safely
be severed from the characters that follow them); and, depending on the
configuration of the collator, characters that have _variable weights_. To be
clear, these are all relatively uncommon scenarios. But the conformance tests
will not pass with anything less than exactitude.

### Multi-Code-Point Weights

I feel bad for hiding this complexity until deep into the post. When I showed
example lines from the DUCET earlier, I chose typical, easy examples. Each of
those lines had one code point mapped to one set of weights. In reality, it can
happen that one code point is mapped to multiple sets of weights, which is easy
to handle; or that a sequence of two or three code points is mapped to one or
more sets of weights, which is rather difficult to handle. Below are examples of
each of these phenomena.

```default
191D      ; [.38DD.0020.0004][.38FB.0020.0004] # LIMBU LETTER GYAN
1B3A      ; [.3C75.0020.0002]                  # BALINESE VOWEL SIGN RA REPA
1B3A 1B35 ; [.3C76.0020.0002]                  # BALINESE VOWEL SIGN RA REPA TEDUNG
```

Imagine that we're iterating through a list of code points from a given string
and building its _collation element array_. If we reach the character `U+191D`,
that's fine---we just have two sets of weights to append to the CEA, rather than
the one that we're accustomed to. But what if we encounter `U+1B3A`? This poses
a real problem: we need to look ahead to the next code point. If what follows is
`U+1B35`, then the UCA requires that we take the two code points as one unit and
use the appropriate collation weights. Otherwise, `U+1B3A` will be handled on
its own.

The number of code points that can begin two-character sequences in the
collation tables is very small in the grand scheme of things: 71 (as of Unicode
version 16). There is an even smaller number of code points that can begin
_three_-character sequences: just 6. Any time that we encounter any of these 77
code points, more complex handling is required. This means, among other things,
that we cannot trim a shared prefix that ends with a character like `U+1B3A`.

If you want to learn more about the treatment of multi-code-point sequences,
fear not---we'll return to this issue in discussing the construction of
collation element arrays. May the gods help us.

### Variable Weights

Here we have an even more outside-the-box concept: there are certain characters
that one might prefer to ignore in collation (at least at the main levels).
These include whitespace characters, punctuation, and some symbols. Take the
following example:

```default
foo baz
foobar
foobaz
```

Does that look wrong to you? It may not; treating the space as an ordinary
character for collation purposes is one valid, common approach. But a user might
prefer to ignore the space at the primary, secondary, and tertiary levels, so
that "foo baz" and "foobaz" would be grouped together, differing only at a
_quaternary_ level. This is known in the UCA as the "shifted" approach, and it
is made possible by the assigning of _variable weights_ to the relevant code
points in the tables.

```default
foobar
foo baz
foobaz
```

If you look in the tables for a character like `U+0020`, the normal space, you
will see that the set of weights has a star at the beginning instead of a
period. This marks it as variable.

```default
0020  ; [*0209.0020.0002] # SPACE
```

A conformant implementation of the UCA needs to be able to handle
variable-weight characters according to either the "non-ignorable" or the
"shifted" approach. There are, in fact, separate conformance tests for them.
I'll come back to this issue later. For the moment, all that we need to
understand is that, when variable weights are being shifted, it has some subtle
effects on the treatment of surrounding characters. This is why we cannot safely
trim a shared prefix from two strings if the "shifted" approach is specified and
the final code point in the prefix has variable weights.

## The Collation Element Array

Now we reach the heart of the matter. I know that I've already gone into some
depth in the preceding sections, but generating the CEA is a different beast. My
primary function in this area is too long---a little over a hundred actual lines
of code, more with comments and empty lines---to show here in full. And that
function, `generateCEA`, calls a number of smaller utility functions that I've
abstracted out.

The easy part to understand is that `generateCEA` takes a list of code points
representing one string, iterates over them, fetches their collation weights,
and appends those to a separate list, namely the CEA. Most of the function takes
place in a `while` loop, which is completed once all the code points have been
processed. The complicated part is that, in each iteration of the big loop,
there are seven possible outcomes for the code point(s) in question. I figure
that I can at least explain those different paths here. I have them labeled in
my code in order of how much work they represent, from least to greatest.

1. A low code point (below `U+00B7`) can be looked up in a small table, its
   weights retrieved very quickly.

2. A higher code point, but one that is still "safe"---i.e., not among the
   possible starters of two- or three-code-point sequences---can be looked up in
   a larger map of weights. This is still quite simple.

3. A code point that is not listed at all in the collation weight tables can
   have its weights calculated algorithmically. These are called "implicit
   weights," and in fact they apply to large swaths of the Unicode space,
   including most ranges of CJK characters. It is to our great benefit that so
   many code points don't need explicitly defined collation weights; the tables
   would otherwise be much, much larger. At any rate, calculating implicit
   weights for the CEA is still a good outcome.

4. We encounter a code point that could begin a multi-character sequence, so we
   look ahead to the next one or two code points. This _does_ yield a match,
   consisting of two code points. The UCA then requires us to check for a third
   character that may be "discontiguous" with the first two---i.e., to look
   further ahead in case of a malformed sequence. This is where I find that the
   UCA rules veer into the ridiculous; but whatever. Outcome 4 is when we check
   for such a discontiguous match and actually find one.

5. We encounter a code point that could begin a multi-character sequence, so we
   look ahead to the next one or two code points. This yields a match. If what
   we found is already a three-code-point sequence, we don't need to look any
   further for a possible discontiguous match, and we can process the weights
   and move on. Alternatively, this path can be reached if we found a
   two-code-point sequence, looked further for a discontiguous match, and failed
   to find one. Outcome 5 could, therefore, be better or worse than 4.

6. At this point, things get weirder. Let's say we encounter a code point that
   could begin a multi-character sequence, so we look ahead to the next one or
   two code points. But we don't find anything. What then? Well, we still need
   to check for a discontiguous match. Outcome 6 is reached if we carry out that
   check and actually find something.

7. Finally, in the most cursed path, we encounter a code point that could begin
   a multi-character sequence, so we look ahead to the next one or two code
   points. We don't find such a sequence initially, so we check for a
   discontiguous match. But we don't find that, either. In the end, we take just
   the one code point with which we started, fetch its weights, and add those to
   the CEA. What a hassle!

From what I've seen, in benchmarks on real-world text data, we exit this loop
via path 1, 2, or 3 almost all the time. So it's not so bad, not terribly
inefficient. But I think the whole matter of "discontiguous matches" in the UCA
is absurd, particularly given that the algorithm requires us to normalize an
input string to form NFD before we even reach this stage. The first time that I
wrote an implementation, in Rust, it took me ages to get the CEA function to a
point where the conformance tests would pass.

If anyone wants more detail on CEA generation, I could certainly provide it. My
inclination, however, is to move on with this post. Once the collation element
arrays are in place, the algorithm can move forward with processing them into
sort keys, which is considerably simpler.

## Sort Keys

If you've read this far, you know how this works. We have two collation element
arrays, each a list of _sets of weights_ pertaining to the input strings of the
collation function, which is charged with returning an ordering
value---something like "less than," "equal to," or "greater than." And all that
we need to do now is to consider the collation weights that we've collected, one
_level_ at a time, one _index_ at a time. As soon as we find a difference, we
return it.

Let me just show you how this looks in code, taking the example of the primary
level. Comments have been added for clarity. This is from `src/sort_key.zig`:

```zig
fn comparePrimary(a_cea: []const u32, b_cea: []const u32) ?std.math.Order {
   // We need separate iterators, advancing to the next nonzero value in each
   var i_a: usize = 0;
   var i_b: usize = 0;

   // Loop until return: a result, or iterator exhaustion
   while (true) {
      const a_p = nextValidPrimary(a_cea, &i_a);
      const b_p = nextValidPrimary(b_cea, &i_b);

      // If we found a difference, return it
      if (a_p != b_p) return util.cmp(u16, a_p, b_p);

      if (a_p == 0) return null; // i.e., both exhausted
   }

   // Assert to the compiler that we will definitely return from the loop
   unreachable;
}
```

For good measure, let's also have a look at the relevant iterator function:

```zig
fn nextValidPrimary(cea: []const u32, i: *usize) u16 {
   while (i.* < cea.len) {
      const nextWeights = cea[i.*];

      // u32 max is used as a sentinel value to end the CEA
      if (nextWeights == std.math.maxInt(u32)) return 0;

      const nextPrimary = primary(nextWeights);
      i.* += 1;

      if (nextPrimary != 0) return nextPrimary;
   }

   return 0;
}
```

As you can see, we progressively find the next nonzero primary weight in each
CEA. The iterator returns zero once it is exhausted. The comparison function, in
turn, returns a null value if no meaningful difference was observed. In that
case, sort key processing would continue to the secondary level, and so on. This
is all straightforward enough.

What may yet be of interest is the handling of variable weights in the "shifted"
approach. How does that actually work? In brief, "shifting" the weights for a
variable-weight character involves setting its secondary and tertiary weights to
zero, and marking it somehow so that its primary weight is ignored at the
primary level. We then add a "quaternary" level of weight comparison, at which
point we consider the _primary_ weights once again---this time including the
previously ignored weights of any variable-weight code points.

In code, all this means is that we have a separate weight comparison function
for the primary level when the "shifted" approach is being followed; and there
is a "quaternary-level" weight comparison at the end, which ends up being a
replay of the primary level, this time not ignoring anything.

```zig
fn comparePrimaryShifting(a_cea: []const u32, b_cea: []const u32) ?std.math.Order {
   var i_a: usize = 0;
   var i_b: usize = 0;

   while (true) {
      const a_p = nextValidPrimaryShifting(a_cea, &i_a);
      const b_p = nextValidPrimaryShifting(b_cea, &i_b);

      if (a_p != b_p) return util.cmp(u16, a_p, b_p);
      if (a_p == 0) return null; // i.e., both exhausted
   }

   unreachable;
}

fn nextValidPrimaryShifting(cea: []const u32, i: *usize) u16 {
   while (i.* < cea.len) {
      const nextWeights = cea[i.*];
      if (nextWeights == std.math.maxInt(u32)) return 0;

      // In this case, we ignore variable weights
      if (variability(nextWeights)) {
         i.* += 1;
         continue;
      }

      const nextPrimary = primary(nextWeights);
      i.* += 1;

      if (nextPrimary != 0) return nextPrimary;
   }

   return 0;
}
```

It's elegant, in its own way: variable weights are handled via primary-level
weights; we simply delay consideration of them until after the tertiary level.

## Performance Optimization

While I've gone over much of the process of the Unicode Collation Algorithm in a
logical sense, figuring this out is only the first part of writing an
implementation. Performance is a major concern. The reality for a collation
function is that it is meant to be plugged into a sort function to be used as
the comparator; and the comparator that the UCA replaces, i.e., naïve comparison
of byte arrays, is _extremely fast_. If Unicode collation is too slow, then
perhaps people won't bother using it. It's already difficult enough to get
programmers to support Unicode-aware systems ("Back in my day, ASCII was more
than sufficient"). Imagine, e.g., integrating a UCA implementation into a DBMS
to sort millions of rows of data. We're fortunate that the Unicode project
[ICU](https://icu.unicode.org/) (International Components for Unicode) maintains
its own standards-compliant and generally highly performant libraries, including
for collation.

One of my [benchmarks](https://github.com/theodore-s-beers/feruca-benchmarks)
uses the full text of the German Wikipedia article on the planet Mars, around
10,000 words, which is split on whitespace and then sorted. On my own laptop, as
of early August 2025, my Rust implementation of the UCA can accomplish this
sorting in about 4.5 ms. Ignoring Unicode and sorting the same data based on
byte values takes only 1.1 ms. The price of Unicode-awareness is always going to
be a slowdown of at least, say, 3x. But that's still fast enough for use in
demanding production systems.

Anyway, how do we even get to that point? If you try the simplest way of
implementing the UCA, that will probably mean looking at code points one at a
time and searching for their weights in the _text files_ of the published
collation weight tables. This will, unsurprisingly, be on the order of hundreds
of times slower. But it was my starting point, and it may be yours, too, if you
ever decide to attack the problem on your own. I'd like to outline some of the
performance improvement strategies that I've applied in the long journey from
"conformant but terrible" to "pretty decent." These are not necessarily in order
of importance, but rather in order of computation. I hope you see what I mean.

1. **Build native data structures ahead of time.** For me, as I mentioned
   before, this means mostly hash maps associating Unicode code points with
   certain key attributes. I have, for example, a map of code points to their
   canonical decompositions (if any); a map that facilitates the "fast NFC/NFD"
   check as an alternative to full normalization; a map of single code points to
   their collation weights (the largest structure by far); and a map of
   multi-code-point sequences to their weights. There are other options; one
   could probably use [tries](https://en.wikipedia.org/wiki/Trie) instead in
   some of these contexts. But I've gotten respectable performance from hash
   tables, given a good hash function.

2. **Pack data** as well, for compactness, hashing efficiency, and speed. You
   may have noticed in code examples above that I have each _set of weights_
   represented as a `u32`, built from something like `[.2422.0020.0002]`. How
   does that work? It turns out that all of the actually used primary weight
   values fit within 16 bits; the secondary weights within 9; and the tertiaries
   within 6. (In fact, there might still be a bit to spare in either the
   secondaries or the tertiaries; I can't recall.) This makes 31 bits, leaving
   one for a flag for variable weights. Packing the weights this way is a fine
   tradeoff: they can be unpacked with minimal effort and no allocation. An even
   neater optimization is enabled by the fact that Unicode code points fall in
   the `u21` range. When we build a map of multi-code-point sequences to their
   collation weights, we can pack those _keys_ into a `u64`, since they consist
   of either two or three code points. This is much better than using, say, a
   vector of `u32` as the key type.

3. **Add fast paths.** As I mentioned earlier, trying to reach a collation
   result by comparing ASCII-range characters at the beginning of the two
   strings is a significant optimization. And it comes into play more than you
   might expect. If we're comparing the names "Björn" and "Dvořák," do we need
   to go through the full UCA? The answer is no, regardless of the fact that the
   strings both contain accents. We can compare their opening characters and
   return at once.

4. **Avoid unnecessary computation.** This is connected to the previous point,
   but here I have in mind the prefix-trimming step. If we're collating, say,
   "Réunionnais" and "Réunionnaise," we shouldn't need to hit the CEA step in
   the algorithm; one string is a prefix of the other (and they include no risky
   characters). _Early return is a blessing._ In more realistic cases, we might
   not avoid generating the collation element arrays, but we can at least limit
   the number of code points to consider.

5. **Favor lazy/incremental computation.** This principle applies to multiple
   parts of my UCA implementation, most obviously when it comes to the sort key.
   If you read the UCA standard, you might get the impression that the next step
   after generating CEAs is to turn each of them into a full sort key---i.e., a
   list of all nonzero primary weights, followed by all nonzero secondaries,
   etc. This is absolutely unnecessary. It's better to compare the CEAs one
   primary weight at a time, then one secondary weight at a time, and so on.
   Most collation decisions are reached at the primary level, after all. How
   often are two strings identical except for diacritics or capitalization? Even
   though incremental generation of sort keys will mean iterating over the CEAs
   more than once in some cases, it still saves time.

6. **Limit and reuse allocations.** When I first started implementing the UCA,
   in Rust, I didn't know much about memory management, and I followed some
   inefficient practices. For example, on each run of the collation function, I
   would allocate new lists of code points for the input strings. A more
   experienced programmer suggested having the `Collator` struct own these
   lists, and just clearing and reusing them in each run. This was a _huge_ win!
   It made my benchmarks run something like three times faster. Ever since then,
   I've been careful about allocating in hot paths. This is the only reason that
   I was subsequently able to write a decent implementation in Zig, where
   there's no alternative to manual memory management.

## What About Tailoring?

I've written a lot here about implementing Unicode collation, deliberately
ignoring a major issue: some different locales demand different approaches to
sorting text! It's not as though the Unicode standard can establish one big
table of collation weights and have it work for everyone in all contexts. People
using, say, an Arabic locale may require that characters in the Arabic script
sort _before_ rather than after the Latin script. The French language as used in
France has subtly different collation rules from Quebec French. German has
different
[alphabetization schemes](https://de.wikipedia.org/wiki/Alphabetische_Sortierung#Deutschland),
one of them "normal," the other intended specifically for lists of names and
often called "phone book order" (not that many of us still live who remember
using phone books).

It would in fact be fair to say that each and every locale involves its own
adjustments to the default collation order---sometimes small, sometimes great. A
table like DUCET is a good starting point, and it comes close to working
out-of-the-box for many languages/locales. But still, a key part of the Unicode
Collation Algorithm is that it is designed to be _tailored_ to meet the needs of
each locale, each set of rules for sorting, each user's preferences. Another
common example is that people sometimes prefer to ignore capitalization
differences when sorting text. This is known as adjusting the _strength_ of
collation, and it is one of the easiest changes to make in the algorithm. Taken
together, the options that exist are effectively limitless.

Why have I held back from discussing tailoring? Because it would require a post
of its own, and this one is already several thousand words long. Furthermore,
developing a conformant implementation of the UCA is a prerequisite for handling
locale tailoring. The algorithm itself is far from trivial, as we've seen.

I'm not going to get into the weeds at this point, but if anyone out there is
interested in learning more about tailoring, I would encourage you to check out
the [Common Locale Data Repository](https://github.com/unicode-org/cldr) (CLDR),
a project of the Unicode Consortium that maintains a huge collection of various
kinds of locale data for software internationalization. There is also a Unicode
[technical standard](https://www.unicode.org/reports/tr35/tr35-collation.html#Collation_Tailorings)
specific to locale tailoring in collation. I'll warn you in advance: it's quite
the rabbit hole.

My own implementations of the UCA have limited support for tailoring.

_To be continued..._
