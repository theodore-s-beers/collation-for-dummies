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
I mean; I've added some comments for clarity.

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
goes through the different steps of the NFD conversion process:

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

Once decomposition has been accomplished, all that is left for NFD is to fix the
order of the code points so that it matches what is expected canonically in the
Unicode standard. This is governed by a property called "canonical combining
class." In the case of what we might refer to as _base letters_, the combining
class is 0, i.e., "not reordered." Such code points are never moved in
normalization. Diacritics, on the other hand, have a variety of nonzero
combining class values; and when they appear next to one another in a sequence,
they must be in order of ascending combining class. The most common scenario in
which this might become an issue is when a letter has two or more diacritics
attached to it. I can say from my own academic background that this happens with
some frequency in Arabic text. There is a diacritic called _shadda_, which
serves to add emphasis to a consonant; and there are other diacritics that serve
as short vowel marks. It is by no means uncommon to see an Arabic letter that
has both a _shadda_ and a vowel mark above it. In such cases, the base letter
would have a combining class of 0, and the multiple diacritics should, ideally,
be set in order of ascending combining class. Let's look at an example:

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

_To be continued..._
