// Port of Paseo 0.2.0's `components/markdown/html-ish.test.ts`, plus a much
// larger body of edge cases the frozen suite leaves unpinned.
//
// Every upstream `it(...)` is carried over verbatim (same input, same
// assertion). The extra groups exist because this module is a hand-written
// parser: the upstream suite covers the happy paths that motivated it, but the
// behaviour that actually matters in production is what happens on malformed,
// hostile or unusual markup — unterminated tags, nested wrappers, backtick
// arithmetic, CRLF, implied closes, raw-text elements. Every expectation below
// that is not from the upstream suite was produced by executing the frozen
// TypeScript under Node against htmlparser2 12.0.0 and copying the result, so
// they pin real upstream behaviour rather than this port's opinion of it.
import 'dart:io';

import 'package:coding_agent_app/core/paseo_html_ish.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fixtures shared with the upstream suite
// ---------------------------------------------------------------------------

const inlineImageBody =
    '<a href="#"><img alt="Priority" '
    'src="https://example.com/assets/priority.svg?v=9" align="top"></a> '
    'Spoofed browser User-Agent allows access control bypass\n'
    '\n'
    'The middleware now trusts any browser-like User-Agent for '
    'unauthenticated requests.\n'
    '\n'
    '```ts\n'
    'const isBrowser = userAgent.includes("Mozilla");\n'
    '```';

const multiDetailsBody =
    '### Bot Review\n'
    '\n'
    '<details>\n'
    '<summary><h3>Important Files Changed</h3></summary>\n'
    '\n'
    '- `packages/server/src/server/session.ts`\n'
    '\n'
    '</details>\n'
    '\n'
    '<details>\n'
    '<summary><h3>Security Findings</h3></summary>\n'
    '\n'
    'No blocking findings.\n'
    '\n'
    '</details>\n'
    '\n'
    '<!-- bot_other_comments_section -->\n'
    '<sub>Reviews (8): Last reviewed commit: “revert: undo parser” | '
    '<a href="https://app.greptile.com">Re-trigger Greptile</a></sub>';

/// Concatenates only the markdown text of a split, which is how the upstream
/// suite asserts that raw tags never survive into rendered text.
String markdownTextOf(String source) => splitHtmlishMarkdown(
  source,
).map((part) => part is MarkdownTextPart ? part.text : '').join();

void main() {
  // -------------------------------------------------------------------------
  // Upstream suite, carried over verbatim
  // -------------------------------------------------------------------------
  group('splitHtmlishMarkdown (upstream suite)', () {
    test('classifies linked HTML images as generic inline images, not block '
        'markdown images', () {
      final parts = splitHtmlishMarkdown(inlineImageBody);

      expect(
        parts[0],
        const MarkdownInlineImagePart(
          alt: 'Priority',
          src: 'https://example.com/assets/priority.svg?v=9',
          flowsWithText: true,
        ),
      );
      expect(
        parts[1],
        const MarkdownTextPart(
          ' Spoofed browser User-Agent allows access control bypass\n'
          '\n'
          'The middleware now trusts any browser-like User-Agent for '
          'unauthenticated requests.\n'
          '\n'
          '```ts\n'
          'const isBrowser = userAgent.includes("Mozilla");\n'
          '```',
        ),
      );
    });

    test(
      'flags both images as flowsWithText when two inline images precede title '
      'text on the same line',
      () {
        const twoImageBody =
            '<a href="#"><img alt="Priority" '
            'src="https://example.com/priority.svg" align="top"></a> '
            '<a href="#"><img alt="Security" '
            'src="https://example.com/security.svg" align="top"></a> '
            '**Title text here**\n'
            '\n'
            'Body paragraph.';

        final parts = splitHtmlishMarkdown(twoImageBody);

        expect(
          parts[0],
          const MarkdownInlineImagePart(
            alt: 'Priority',
            src: 'https://example.com/priority.svg',
            flowsWithText: true,
          ),
        );
        expect(parts[1], const MarkdownTextPart(' '));
        expect(
          parts[2],
          const MarkdownInlineImagePart(
            alt: 'Security',
            src: 'https://example.com/security.svg',
            flowsWithText: true,
          ),
        );
      },
    );

    test('keeps safe width and height attributes on inline images', () {
      expect(
        splitHtmlishMarkdown(
          '<img alt="Small" src="https://example.com/small.svg" width="18" '
          'height="12">',
        ),
        [
          const MarkdownInlineImagePart(
            alt: 'Small',
            src: 'https://example.com/small.svg',
            width: 18,
            height: 12,
          ),
        ],
      );
    });

    test('keeps safe non-empty image links', () {
      expect(
        splitHtmlishMarkdown(
          '<a href="https://example.com/details"><img alt="Small" '
          'src="https://example.com/small.svg"></a>',
        ),
        [
          const MarkdownInlineImagePart(
            alt: 'Small',
            src: 'https://example.com/small.svg',
            href: 'https://example.com/details',
          ),
        ],
      );
    });

    test('preserves inline image parts inside details bodies', () {
      expect(
        splitHtmlishMarkdown(
          '<details><summary>Images</summary>'
          '<a href="https://example.com/page">'
          '<img alt="Icon" src="https://example.com/icon.svg"></a> '
          'Inline text</details>',
        ),
        [
          const MarkdownDetailsPart(
            summary: 'Images',
            body: 'Inline text',
            bodyParts: [
              MarkdownInlineImagePart(
                alt: 'Icon',
                src: 'https://example.com/icon.svg',
                href: 'https://example.com/page',
                flowsWithText: true,
              ),
              MarkdownTextPart(' Inline text'),
            ],
          ),
        ],
      );
    });

    test('does not flag standalone inline images as flowing with text', () {
      expect(
        splitHtmlishMarkdown(
          '<img alt="Shot" src="https://example.com/shot.png">\n\n'
          'Caption below',
        ),
        [
          const MarkdownInlineImagePart(
            alt: 'Shot',
            src: 'https://example.com/shot.png',
          ),
          const MarkdownTextPart('\n\nCaption below'),
        ],
      );
    });

    test('does not flag mid-line inline images as flowing with text', () {
      final parts = splitHtmlishMarkdown(
        'Before <img alt="Icon" src="https://example.com/icon.png"> after',
      );

      expect(
        parts[1],
        const MarkdownInlineImagePart(
          alt: 'Icon',
          src: 'https://example.com/icon.png',
        ),
      );
    });

    test('leaves ordinary markdown images on the markdown path', () {
      const source = '![Ordinary](https://example.com/full-size.png)';

      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });

    test('leaves unsafe HTML image sources inert', () {
      const source = '<img alt="Bad" src="javascript:alert(1)">';

      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });

    test(
      'removes raw image anchor and image tags from rendered markdown text',
      () {
        final text = markdownTextOf(inlineImageBody);

        expect(text, isNot(contains('<a ')));
        expect(text, isNot(contains('<img ')));
        expect(text, isNot(contains('</a>')));
      },
    );

    test('unwraps sub text and strips HTML comments', () {
      final parts = splitHtmlishMarkdown(multiDetailsBody);

      expect(
        parts.last,
        const MarkdownTextPart(
          '\n\nReviews (8): Last reviewed commit: '
          '“revert: undo parser” | '
          '[Re-trigger Greptile](https://app.greptile.com)',
        ),
      );
    });

    test(
      'does not leak stray closing details tags across multiple details blocks',
      () {
        final renderedText = splitHtmlishMarkdown(multiDetailsBody)
            .map(
              (part) => switch (part) {
                MarkdownTextPart() => part.text,
                MarkdownDetailsPart() => '${part.summary}\n${part.body}',
                MarkdownInlineImagePart() => part.alt,
              },
            )
            .join('\n');

        expect(renderedText, isNot(contains('</details>')));
        expect(renderedText, isNot(contains('<!--')));

        final head = splitHtmlishMarkdown(multiDetailsBody).sublist(0, 4);
        expect(head[0], const MarkdownTextPart('### Bot Review\n\n'));
        expect(head[1], isA<MarkdownDetailsPart>());
        expect(
          (head[1] as MarkdownDetailsPart).summary,
          'Important Files Changed',
        );
        expect(head[2], const MarkdownTextPart('\n\n'));
        expect(head[3], isA<MarkdownDetailsPart>());
        expect((head[3] as MarkdownDetailsPart).summary, 'Security Findings');
      },
    );

    test(
      'preserves paragraph boundaries around title, prose, and code block',
      () {
        final text = markdownTextOf(inlineImageBody);

        expect(
          text,
          contains(
            'Spoofed browser User-Agent allows access control bypass\n\n'
            'The middleware now trusts',
          ),
        );
        expect(
          text,
          contains('unauthenticated requests.\n\n```ts\nconst isBrowser'),
        );
      },
    );

    test('keeps product-specific image language out of parser logic', () {
      // Upstream scans `html-ish.ts` and `renderer.tsx`; only the parser is
      // ported, so only the parser is scanned here. The property is the same:
      // no vendor or severity vocabulary may leak into generic parsing code.
      final parser = File('lib/core/paseo_html_ish.dart').existsSync()
          ? File('lib/core/paseo_html_ish.dart')
          : File('packages/app/lib/core/paseo_html_ish.dart');
      expect(
        parser.existsSync(),
        isTrue,
        reason: 'parser source must be readable from ${Directory.current.path}',
      );

      expect(
        parser.readAsStringSync(),
        isNot(
          matches(
            RegExp(
              'Greptile|badge|P0|P1|P2|greptile-static-assets',
              caseSensitive: false,
            ),
          ),
        ),
      );
    });

    test('parses Greptile-style details blocks', () {
      expect(
        splitHtmlishMarkdown(
          '<details><summary><h3>Greptile Summary</h3></summary>'
          'Body markdown</details>',
        ),
        [
          const MarkdownDetailsPart(
            summary: 'Greptile Summary',
            body: 'Body markdown',
          ),
        ],
      );
    });

    test('keeps details inside fenced code as literal markdown', () {
      const source =
          '```html\n<details><summary>Example</summary>Body</details>\n```';

      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });

    test('keeps details inside inline code on native runtimes without copied '
        'array sorting', () {
      // Upstream deletes `Array.prototype.toSorted` to prove the merge step
      // does not depend on it. Dart has no such optional method, so the
      // guarantee holds structurally; the assertion is kept so the case is
      // still covered.
      const source =
          'Use `<details><summary>Example</summary>Body</details>` '
          'as an example.';

      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });

    test('keeps details inside inline code as literal markdown', () {
      const source =
          'Use `<details><summary>Example</summary>Body</details>` '
          'as an example.';

      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });

    test(
      'terminates when an unmatched backtick follows a closed inline code span',
      () {
        const source =
            'Use `<details><summary>Example</summary>Body</details>` '
            'before `dangling';

        expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
      },
    );

    test('still parses normal details outside code', () {
      expect(
        splitHtmlishMarkdown(
          '`code`\n<details><summary>Real</summary>Body</details>',
        ),
        [
          const MarkdownTextPart('`code`\n'),
          const MarkdownDetailsPart(summary: 'Real', body: 'Body'),
        ],
      );
    });

    test('preserves text before and after details blocks', () {
      expect(
        splitHtmlishMarkdown(
          'Before\n<details><summary>More</summary>Hidden</details>\nAfter',
        ),
        [
          const MarkdownTextPart('Before\n'),
          const MarkdownDetailsPart(summary: 'More', body: 'Hidden'),
          const MarkdownTextPart('\nAfter'),
        ],
      );
    });

    test('parses multiple details blocks', () {
      expect(
        splitHtmlishMarkdown(
          '<details><summary>One</summary>A</details>'
          '<details><summary>Two</summary>B</details>',
        ),
        [
          const MarkdownDetailsPart(summary: 'One', body: 'A'),
          const MarkdownDetailsPart(summary: 'Two', body: 'B'),
        ],
      );
    });

    test('normalizes br and simple code tags into markdown', () {
      expect(
        normalizeHtmlishMarkdown('Line 1<br/>Line 2 <code>safe-value</code>'),
        'Line 1\nLine 2 `safe-value`',
      );
    });

    test('leaves complex code tags inert instead of parsing HTML', () {
      expect(
        normalizeHtmlishMarkdown(
          '<code onclick="evil()"><script>x</script></code>',
        ),
        '<code onclick="evil()"><script>x</script></code>',
      );
    });

    test('falls back to inert markdown when details are unclosed', () {
      const source = '<details><summary>Open</summary>Still open';

      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });

    test('falls back to inert markdown when summary is missing', () {
      const source = '<details>Hidden</details>';

      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });

    test('does not execute or render unknown HTML as structured content', () {
      const source =
          '<script>alert(1)</script><details onclick="evil()">'
          '<summary>Safe</summary><iframe src="x"></iframe></details>';

      expect(splitHtmlishMarkdown(source), [
        const MarkdownTextPart('<script>alert(1)</script>'),
        const MarkdownDetailsPart(
          summary: 'Safe',
          body: '<iframe src="x"></iframe>',
        ),
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // Extra coverage: image flow detection
  // -------------------------------------------------------------------------
  group('inline image flow detection', () {
    test(
      'an image opening the source flows into trailing text on its line',
      () {
        expect(
          splitHtmlishMarkdown(
            '<img src="https://a/b.png" alt="A">   trailing',
          ),
          [
            const MarkdownInlineImagePart(
              alt: 'A',
              src: 'https://a/b.png',
              flowsWithText: true,
            ),
            const MarkdownTextPart('   trailing'),
          ],
        );
      },
    );

    test('a tab between image and text still counts as the same line', () {
      expect(splitHtmlishMarkdown('<img src="https://a/b.png" alt="A">\t z'), [
        const MarkdownInlineImagePart(
          alt: 'A',
          src: 'https://a/b.png',
          flowsWithText: true,
        ),
        const MarkdownTextPart('\t z'),
      ]);
    });

    test('an image after a newline still opens its own line', () {
      expect(
        splitHtmlishMarkdown('line\n<img src="https://a/b.png" alt="A"> text'),
        [
          const MarkdownTextPart('line\n'),
          const MarkdownInlineImagePart(
            alt: 'A',
            src: 'https://a/b.png',
            flowsWithText: true,
          ),
          const MarkdownTextPart(' text'),
        ],
      );
    });

    test(
      'leading indentation does not stop an image from opening its line',
      () {
        expect(
          splitHtmlishMarkdown(
            'line\n  <img src="https://a/b.png" alt="A"> text',
          ),
          [
            const MarkdownTextPart('line\n  '),
            const MarkdownInlineImagePart(
              alt: 'A',
              src: 'https://a/b.png',
              flowsWithText: true,
            ),
            const MarkdownTextPart(' text'),
          ],
        );
      },
    );

    test('a newline between image and text breaks the flow', () {
      expect(splitHtmlishMarkdown('<img src="https://a/b.png" alt="A"> \n z'), [
        const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
        const MarkdownTextPart(' \n z'),
      ]);
    });

    test('CRLF after an image breaks the flow', () {
      expect(
        splitHtmlishMarkdown(
          '<img src="https://a/b.png" alt="A">\r\nnext line',
        ),
        [
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
          const MarkdownTextPart('\r\nnext line'),
        ],
      );
    });

    test(
      'only the first of two directly adjacent images flows with the text',
      () {
        // The second image is preceded by a tag token, not by line-leading
        // whitespace, so it is not considered to start the line.
        expect(
          splitHtmlishMarkdown(
            '<img src="https://a/b.png" alt="A">'
            '<img src="https://a/c.png" alt="B"> text',
          ),
          [
            const MarkdownInlineImagePart(
              alt: 'A',
              src: 'https://a/b.png',
              flowsWithText: true,
            ),
            const MarkdownInlineImagePart(alt: 'B', src: 'https://a/c.png'),
            const MarkdownTextPart(' text'),
          ],
        );
      },
    );

    test('images on a line of their own do not flow with the next line', () {
      expect(
        splitHtmlishMarkdown(
          '<img src="https://a/b.png" alt="A"> '
          '<img src="https://a/c.png" alt="B">\ntext',
        ),
        [
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
          const MarkdownTextPart(' '),
          const MarkdownInlineImagePart(alt: 'B', src: 'https://a/c.png'),
          const MarkdownTextPart('\ntext'),
        ],
      );
    });

    test(
      'a preceding inline code span stops an image from opening its line',
      () {
        expect(
          splitHtmlishMarkdown('`a`<img src="https://a/b.png" alt="A"> text'),
          [
            const MarkdownTextPart('`a`'),
            const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
            const MarkdownTextPart(' text'),
          ],
        );
      },
    );

    test(
      'a following inline code span counts as substantive same-line text',
      () {
        expect(
          splitHtmlishMarkdown(
            '<img src="https://a/b.png" alt="A">`code` more',
          ),
          [
            const MarkdownInlineImagePart(
              alt: 'A',
              src: 'https://a/b.png',
              flowsWithText: true,
            ),
            const MarkdownTextPart('`code` more'),
          ],
        );
      },
    );

    test('a preceding comment stops an image from opening its line', () {
      // The comment token is not text, so the line-start test fails.
      expect(
        splitHtmlishMarkdown('<!-- c --><img src="https://a/b.png" alt="A"> z'),
        [
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
          const MarkdownTextPart(' z'),
        ],
      );
    });

    test('a comment between image and text stops the forward scan', () {
      expect(
        splitHtmlishMarkdown('<img src="https://a/b.png" alt="A"><!-- c --> z'),
        [
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
          const MarkdownTextPart(' z'),
        ],
      );
    });

    test('a bare leading newline still leaves the image at a line start', () {
      expect(splitHtmlishMarkdown('\n<img src="https://a/b.png" alt="A"> z'), [
        const MarkdownTextPart('\n'),
        const MarkdownInlineImagePart(
          alt: 'A',
          src: 'https://a/b.png',
          flowsWithText: true,
        ),
        const MarkdownTextPart(' z'),
      ]);
    });

    test('a line separator is not a line break for flow purposes', () {
      // `U+2028` is a line start for the fence regex but not for this check,
      // which only looks at `\n` and `\r`.
      expect(
        splitHtmlishMarkdown('\u2028<img src="https://a/b.png" alt="A"> text'),
        [
          const MarkdownTextPart('\u2028'),
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
          const MarkdownTextPart(' text'),
        ],
      );
    });

    test('trailing whitespace alone is not substantive text', () {
      expect(splitHtmlishMarkdown('<img src="https://a/b.png" alt="A">  '), [
        const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
        const MarkdownTextPart('  '),
      ]);
    });

    test('a self-closing image followed by text flows with it', () {
      expect(
        splitHtmlishMarkdown('<img alt="A" src="https://a/b.png" /> text'),
        [
          const MarkdownInlineImagePart(
            alt: 'A',
            src: 'https://a/b.png',
            flowsWithText: true,
          ),
          const MarkdownTextPart(' text'),
        ],
      );
    });
  });

  // -------------------------------------------------------------------------
  // Extra coverage: image and link safety
  // -------------------------------------------------------------------------
  group('image and link safety', () {
    test('accepts every allow-listed data image subtype', () {
      for (final source in const [
        'data:image/png;base64,AAA',
        'data:image/gif;base64,AAA',
        'data:image/jpg;base64,AAA',
        'data:image/jpeg;base64,AAA',
      ]) {
        expect(splitHtmlishMarkdown('<img src="$source" alt="A">'), [
          MarkdownInlineImagePart(alt: 'A', src: source),
        ], reason: source);
      }
    });

    test('the source allow-list is case-insensitive', () {
      expect(
        splitHtmlishMarkdown('<img src="DATA:IMAGE/PNG;BASE64,AAA" alt="Up">'),
        [
          const MarkdownInlineImagePart(
            alt: 'Up',
            src: 'DATA:IMAGE/PNG;BASE64,AAA',
          ),
        ],
      );
      expect(splitHtmlishMarkdown('<img src="HTTPS://A/B.PNG" alt="A">'), [
        const MarkdownInlineImagePart(alt: 'A', src: 'HTTPS://A/B.PNG'),
      ]);
    });

    test('rejects data image subtypes outside the allow-list', () {
      const source = '<img src="data:image/svg+xml;base64,AAA" alt="Svg">';

      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });

    test('rejects protocol-relative sources', () {
      const source = '<img src="//example.com/a.png" alt="A">';

      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });

    test('an empty src is inert, and re-renders as a bare attribute', () {
      // The reconstructed tag drops `=""`, which is how empty attributes are
      // rendered throughout.
      expect(
        normalizeHtmlishMarkdown('<img src="" alt="A">'),
        '<img src alt="A">',
      );
    });

    test('an unsafe image inside a link leaves both inert', () {
      expect(
        normalizeHtmlishMarkdown(
          '<a href="https://x"><img src="javascript:x" alt="A"></a>',
        ),
        '<img src="javascript:x" alt="A">',
      );
    });

    test('a `#` href is dropped from an image link', () {
      expect(
        splitHtmlishMarkdown(
          '<a href="#"><img src="https://a/b.png" alt="A"></a>',
        ),
        [const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png')],
      );
    });

    test('a missing href is dropped from an image link', () {
      expect(
        splitHtmlishMarkdown('<a><img src="https://a/b.png" alt="A"></a>'),
        [const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png')],
      );
    });

    test('comments inside a link do not stop the single-image match', () {
      expect(
        splitHtmlishMarkdown(
          '<a href="https://x"><!-- c --><img src="https://a/b.png" alt="A"></a>',
        ),
        [
          const MarkdownInlineImagePart(
            alt: 'A',
            src: 'https://a/b.png',
            href: 'https://x',
          ),
        ],
      );
    });

    test('two images inside one link are not a single linked image', () {
      expect(
        splitHtmlishMarkdown(
          '<a href="https://x"><img src="https://a/b.png" alt="A">'
          '<img src="https://a/c.png" alt="B"></a>',
        ),
        [
          const MarkdownTextPart('<a href="https://x">'),
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
          const MarkdownInlineImagePart(alt: 'B', src: 'https://a/c.png'),
        ],
      );
    });

    test('nesting makes the inner anchor supply the href', () {
      // `<a>` implies the close of an open `<a>`, so the outer open tag is
      // left dangling and re-emitted literally.
      expect(
        splitHtmlishMarkdown(
          '<a href="https://x"><a href="https://y">'
          '<img src="https://a/b.png" alt="A"></a></a>',
        ),
        [
          const MarkdownTextPart('<a href="https://x">'),
          const MarkdownInlineImagePart(
            alt: 'A',
            src: 'https://a/b.png',
            href: 'https://y',
          ),
        ],
      );
    });

    test('an unterminated link leaves the open tag literal', () {
      expect(
        splitHtmlishMarkdown(
          '<a href="https://x"><img src="https://a/b.png" alt="A">',
        ),
        [
          const MarkdownTextPart('<a href="https://x">'),
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
        ],
      );
    });

    test('anchor links keep only non-empty in-page targets', () {
      expect(
        normalizeHtmlishMarkdown('<a href="#anchor">Anchor</a>'),
        '[Anchor](#anchor)',
      );
      expect(normalizeHtmlishMarkdown('<a href="#-">Dash</a>'), '[Dash](#-)');
      expect(
        normalizeHtmlishMarkdown('<a href="#_">Underscore</a>'),
        '[Underscore](#_)',
      );
      expect(normalizeHtmlishMarkdown('<a href="#">Hash</a>'), 'Hash');
      expect(normalizeHtmlishMarkdown('<a href="# ">Space</a>'), 'Space');
    });

    test('unsafe link targets keep the label and drop the link', () {
      expect(
        normalizeHtmlishMarkdown('<a href="javascript:alert(1)">Evil</a>'),
        'Evil',
      );
    });

    test('an empty label produces no output at all', () {
      expect(
        splitHtmlishMarkdown('<a href="https://example.com"></a>'),
        isEmpty,
      );
    });

    test(
      'link targets are matched case-insensitively and emitted verbatim',
      () {
        expect(
          normalizeHtmlishMarkdown('<A HREF="HTTPS://EXAMPLE.COM">Label</A>'),
          '[Label](HTTPS://EXAMPLE.COM)',
        );
        expect(
          normalizeHtmlishMarkdown('<a href="HTTP://X">Upper</a>'),
          '[Upper](HTTP://X)',
        );
      },
    );

    test('quoted, single-quoted and unquoted hrefs parse alike', () {
      expect(
        normalizeHtmlishMarkdown("<a href='https://example.com'>Single</a>"),
        '[Single](https://example.com)',
      );
      expect(
        normalizeHtmlishMarkdown('<a href=https://example.com>Unquoted</a>'),
        '[Unquoted](https://example.com)',
      );
    });

    test('link labels keep their own inline rewriting', () {
      expect(
        normalizeHtmlishMarkdown(
          '<a href="https://a.example">Text <code>x</code> more</a>',
        ),
        '[Text `x` more](https://a.example)',
      );
      expect(
        normalizeHtmlishMarkdown('<a href="https://x">a<br>b</a>'),
        '[a\nb](https://x)',
      );
      expect(
        normalizeHtmlishMarkdown('<a href="https://x"><sub>s</sub></a>'),
        '[s](https://x)',
      );
      expect(
        normalizeHtmlishMarkdown('<a href="https://x"><h3>h</h3></a>'),
        '[h](https://x)',
      );
      expect(
        normalizeHtmlishMarkdown('<a href="https://x"><span>s</span></a>'),
        '[<span>s</span>](https://x)',
      );
    });

    test(
      'closing brackets in alt text are escaped when rendered as markdown',
      () {
        expect(
          normalizeHtmlishMarkdown(
            '<img src="https://example.com/a.png" alt="a]b]c">',
          ),
          r'![a\]b\]c](https://example.com/a.png)',
        );
      },
    );

    test('a missing alt becomes an empty alt', () {
      expect(splitHtmlishMarkdown('<img src="https://example.com/a.png">'), [
        const MarkdownInlineImagePart(
          alt: '',
          src: 'https://example.com/a.png',
        ),
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // Extra coverage: image dimensions
  // -------------------------------------------------------------------------
  group('image dimensions', () {
    void expectDimensions(String attributes, {double? width, double? height}) {
      expect(
        splitHtmlishMarkdown('<img src="https://a/b.png" $attributes>'),
        [
          MarkdownInlineImagePart(
            alt: '',
            src: 'https://a/b.png',
            width: width,
            height: height,
          ),
        ],
        reason: attributes,
      );
    }

    test('zero is rejected but other integers are kept', () {
      expectDimensions('width="0" height="5"', height: 5);
      expectDimensions('width="007"', width: 7);
    });

    test('fractional dimensions are kept', () {
      expectDimensions('width="1.5"', width: 1.5);
      expectDimensions('width="0.5"', width: 0.5);
    });

    test(
      'non-numeric, padded, signed, exponent and trailing-dot forms are rejected',
      () {
        expectDimensions('width="1.5" height="abc"', width: 1.5);
        expectDimensions('width=" 18"');
        expectDimensions('width="+12"');
        expectDimensions('width="1e3"');
        expectDimensions('width="12."');
      },
    );

    test('a huge dimension still parses as a finite double', () {
      expectDimensions('width="99999999999999999999"', width: 1e20);
    });
  });

  // -------------------------------------------------------------------------
  // Extra coverage: details blocks
  // -------------------------------------------------------------------------
  group('details blocks', () {
    test('a nested details block becomes a body part of its parent', () {
      expect(
        splitHtmlishMarkdown(
          '<details><summary>Outer</summary>x'
          '<details><summary>Inner</summary>y</details>z</details>',
        ),
        [
          const MarkdownDetailsPart(
            summary: 'Outer',
            body: 'xz',
            bodyParts: [
              MarkdownTextPart('x'),
              MarkdownDetailsPart(summary: 'Inner', body: 'y'),
              MarkdownTextPart('z'),
            ],
          ),
        ],
      );
    });

    test(
      'a details block whose only body is another details keeps an empty body',
      () {
        expect(
          splitHtmlishMarkdown(
            '<details><summary>S</summary>'
            '<details><summary>T</summary>u</details></details>',
          ),
          [
            const MarkdownDetailsPart(
              summary: 'S',
              body: '',
              bodyParts: [MarkdownDetailsPart(summary: 'T', body: 'u')],
            ),
          ],
        );
      },
    );

    test('body parts are trimmed at both ends and emptied parts dropped', () {
      expect(
        splitHtmlishMarkdown(
          '<details><summary>S</summary>\n'
          '<img src="https://a/b.png" alt="A">\n</details>',
        ),
        [
          const MarkdownDetailsPart(
            summary: 'S',
            body: '',
            bodyParts: [
              MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
            ],
          ),
        ],
      );
    });

    test('a body that is only markdown carries no body parts', () {
      expect(
        splitHtmlishMarkdown(
          '<details><summary>S</summary>   plain   </details>',
        ),
        [const MarkdownDetailsPart(summary: 'S', body: 'plain')],
      );
      expect(splitHtmlishMarkdown('<details><summary>S</summary> </details>'), [
        const MarkdownDetailsPart(summary: 'S', body: ''),
      ]);
    });

    test('content before the summary still belongs to the body', () {
      expect(
        splitHtmlishMarkdown(
          '<details><img src="https://a/b.png" alt="A">'
          '<summary>S</summary>body</details>',
        ),
        [
          const MarkdownDetailsPart(
            summary: 'S',
            body: 'body',
            bodyParts: [
              MarkdownInlineImagePart(
                alt: 'A',
                src: 'https://a/b.png',
                flowsWithText: true,
              ),
              MarkdownTextPart('body'),
            ],
          ),
        ],
      );
    });

    test('a whitespace-only summary makes the block inert', () {
      for (final source in const [
        '<details><summary>   </summary>Body</details>',
        '<details><summary> </summary>B</details>',
        '<details><summary></summary>x</details>',
        '<details><summary><!-- x --></summary>body</details>',
      ]) {
        expect(splitHtmlishMarkdown(source).length, 1, reason: source);
        expect(
          splitHtmlishMarkdown(source).first,
          isA<MarkdownTextPart>(),
          reason: source,
        );
      }
    });

    test(
      'a summary keeps inline rewriting but loses a whole-summary heading',
      () {
        expect(
          splitHtmlishMarkdown(
            '<details><summary><h1>H</h1></summary>body</details>',
          ),
          [const MarkdownDetailsPart(summary: 'H', body: 'body')],
        );
        expect(
          splitHtmlishMarkdown(
            '<details><summary><h6>H</h6></summary>body</details>',
          ),
          [const MarkdownDetailsPart(summary: 'H', body: 'body')],
        );
        expect(
          splitHtmlishMarkdown(
            '<details><summary>A<br>B</summary>body</details>',
          ),
          [const MarkdownDetailsPart(summary: 'A\nB', body: 'body')],
        );
        expect(
          splitHtmlishMarkdown(
            '<details><summary><code>x</code></summary>body</details>',
          ),
          [const MarkdownDetailsPart(summary: '`x`', body: 'body')],
        );
        expect(
          splitHtmlishMarkdown(
            '<details><summary><a href="https://x">L</a></summary>body</details>',
          ),
          [const MarkdownDetailsPart(summary: '[L](https://x)', body: 'body')],
        );
      },
    );

    test(
      'a heading that does not span the whole summary is unwrapped in place',
      () {
        // The wrapper strip only fires when the heading is the outermost, sole
        // element; otherwise the ordinary heading rewrite still applies.
        expect(
          splitHtmlishMarkdown(
            '<details><summary><h3>A</h3> tail</summary>Body</details>',
          ),
          [const MarkdownDetailsPart(summary: 'A tail', body: 'Body')],
        );
        expect(
          splitHtmlishMarkdown(
            '<details><summary><h3>A</h3><h3>B</h3></summary>body</details>',
          ),
          [const MarkdownDetailsPart(summary: 'AB', body: 'body')],
        );
      },
    );

    test('a details block with an empty body still parses', () {
      expect(
        splitHtmlishMarkdown(
          '<details><summary><h3>A</h3></summary></details>',
        ),
        [const MarkdownDetailsPart(summary: 'A', body: '')],
      );
    });

    test('script and style bodies survive as literal text inside details', () {
      // Erasure only happens for a `<script>` with no matching close; a closed
      // one is emitted whole so nothing is silently deleted.
      expect(
        splitHtmlishMarkdown(
          '<details><summary>S</summary><script>evil()</script>body</details>',
        ),
        [
          const MarkdownDetailsPart(
            summary: 'S',
            body: '<script>evil()</script>body',
          ),
        ],
      );
    });

    test('an orphan summary and a stray close tag stay inert', () {
      expect(splitHtmlishMarkdown('<summary>orphan</summary>'), [
        const MarkdownTextPart('<summary>orphan</summary>'),
      ]);
      expect(splitHtmlishMarkdown('</details>stray'), [
        const MarkdownTextPart('stray'),
      ]);
      expect(splitHtmlishMarkdown('<details></details>'), [
        const MarkdownTextPart('<details></details>'),
      ]);
    });

    test('details blocks interleave with surrounding text', () {
      expect(
        splitHtmlishMarkdown(
          'a<details><summary>S</summary>b</details>c'
          '<details><summary>T</summary>d</details>e',
        ),
        [
          const MarkdownTextPart('a'),
          const MarkdownDetailsPart(summary: 'S', body: 'b'),
          const MarkdownTextPart('c'),
          const MarkdownDetailsPart(summary: 'T', body: 'd'),
          const MarkdownTextPart('e'),
        ],
      );
    });

    test('details blocks interleave with inline images', () {
      expect(
        splitHtmlishMarkdown(
          '<img src="https://a/b.png" alt="A">'
          '<details><summary>S</summary>b</details>',
        ),
        [
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
          const MarkdownDetailsPart(summary: 'S', body: 'b'),
        ],
      );
      expect(
        splitHtmlishMarkdown(
          '<details><summary>S</summary>b</details>'
          '<img src="https://a/b.png" alt="A">',
        ),
        [
          const MarkdownDetailsPart(summary: 'S', body: 'b'),
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
        ],
      );
    });

    test('a lead image and its paragraph survive inside a details body', () {
      expect(
        splitHtmlishMarkdown(
          '<details><summary>S</summary>\n\n'
          '<img src="https://a/b.png" alt="A"> Lead\n\nRest\n\n</details>',
        ),
        [
          const MarkdownDetailsPart(
            summary: 'S',
            body: 'Lead\n\nRest',
            bodyParts: [
              MarkdownInlineImagePart(
                alt: 'A',
                src: 'https://a/b.png',
                flowsWithText: true,
              ),
              MarkdownTextPart(' Lead\n\nRest'),
            ],
          ),
        ],
      );
    });

    test('a truncated summary or close tag falls back to inert markdown', () {
      expect(splitHtmlishMarkdown('<details><summary>S'), [
        const MarkdownTextPart('<details><summary>S'),
      ]);
      // The unterminated `</summary` is dropped entirely by the tokenizer.
      expect(splitHtmlishMarkdown('<details><summary>S</summary'), [
        const MarkdownTextPart('<details><summary>S'),
      ]);
    });

    test('tag names and whitespace inside tags are normalised', () {
      expect(
        splitHtmlishMarkdown('<DETAILS><SUMMARY>Caps</SUMMARY>Body</DETAILS>'),
        [const MarkdownDetailsPart(summary: 'Caps', body: 'Body')],
      );
      expect(
        splitHtmlishMarkdown(
          '<details\n><summary\n>S</summary\n>B</details\n>',
        ),
        [const MarkdownDetailsPart(summary: 'S', body: 'B')],
      );
      expect(
        splitHtmlishMarkdown('<details><summary>S</summary>B</details/>'),
        [const MarkdownDetailsPart(summary: 'S', body: 'B')],
      );
    });

    test('a self-closing details does not open a block', () {
      // The self-closing slash is ignored for `selfClosing`, but the parser
      // still closes the element, so no close token is ever emitted.
      expect(
        normalizeHtmlishMarkdown('<details/><summary>x</summary>'),
        '<details><summary>x</summary>',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Extra coverage: markdown code protection
  // -------------------------------------------------------------------------
  group('markdown code protection', () {
    void expectInert(String source) {
      expect(splitHtmlishMarkdown(source), [
        MarkdownTextPart(source),
      ], reason: source);
    }

    test('tilde fences protect their contents', () {
      expectInert('~~~\n<details><summary>x</summary>y</details>\n~~~');
    });

    test('a fence closes only on a run at least as long as the opener', () {
      expectInert('~~~js\n~~~~\n~~~');
      expectInert('````\n```\n````');
      expectInert('```\n```\n```\n```');
    });

    test('up to three spaces of indentation still opens a fence', () {
      expectInert('   ```\ncode\n```\ntail');
    });

    test('four spaces is an indented code line, not a fence', () {
      expectInert('    ```\nnot a fence\n```');
    });

    test('an unterminated fence swallows the rest of the source', () {
      expectInert('```\nunterminated <details><summary>a</summary>b</details>');
    });

    test('trailing spaces after a fence marker do not stop it', () {
      expectInert('``` \n<details><summary>x</summary>y</details>\n``` ');
    });

    test('CRLF fences protect their contents and text resumes after them', () {
      expect(
        splitHtmlishMarkdown(
          '```ts\r\nconst a = 1;\r\n```\r\n'
          '<img src="https://a/b.png" alt="After">',
        ),
        [
          const MarkdownTextPart('```ts\r\nconst a = 1;\r\n```\r\n'),
          const MarkdownInlineImagePart(alt: 'After', src: 'https://a/b.png'),
        ],
      );
    });

    test('a lone CR is a line terminator for fence matching', () {
      expectInert('```ts\rconst a = 1\r```\rtail');
    });

    test('inline code spans close only on a run of the same length', () {
      expectInert('``a ` b``  and `c`');
      expectInert('`a``b`');
      expectInert('a `b` c `d` e');
      expectInert('`` ` ``');
    });

    test('unmatched backtick runs do not restart the scan', () {
      expectInert('`');
      expectInert('``');
      expectInert('a ``` b');
      expectInert('text ` one ` two ` three ` four');
    });

    test('an inline code span may span lines', () {
      expectInert('``\ncode\n``');
    });

    test('HTML inside inline code is not parsed', () {
      expectInert('`<img src="https://a/b.png" alt="A">`');
    });

    test('backticks inside an attribute value are still protected as code', () {
      // The protection pass runs on raw source, before any HTML is understood,
      // so the code span wins and the surviving tag has no `alt`.
      expect(splitHtmlishMarkdown('<img src="https://a/b.png" alt="`A`">'), [
        const MarkdownTextPart('`A`'),
        const MarkdownInlineImagePart(alt: '', src: 'https://a/b.png'),
      ]);
    });

    test('markdown entities are never decoded', () {
      expectInert('&amp; &lt; stays');
    });
  });

  // -------------------------------------------------------------------------
  // Extra coverage: inline rewriting
  // -------------------------------------------------------------------------
  group('inline rewriting', () {
    test('br becomes a newline whether or not it is self-closed', () {
      expect(normalizeHtmlishMarkdown('<br>'), '\n');
      expect(normalizeHtmlishMarkdown('<br/>'), '\n');
    });

    test('a stray closing br produces nothing', () {
      expect(normalizeHtmlishMarkdown('</br>'), '');
      expect(splitHtmlishMarkdown('</br>'), isEmpty);
    });

    test('a stray closing p produces nothing', () {
      expect(splitHtmlishMarkdown('</p>'), isEmpty);
    });

    test('sub is unwrapped, including when nested', () {
      expect(normalizeHtmlishMarkdown('<sub>plain</sub>'), 'plain');
      expect(normalizeHtmlishMarkdown('<sub>a<sub>b</sub>c</sub>'), 'abc');
      expect(
        normalizeHtmlishMarkdown('<sub>a<a href="https://x">b</a>c</sub>'),
        'a[b](https://x)c',
      );
    });

    test('headings are unwrapped, but only when balanced', () {
      expect(
        normalizeHtmlishMarkdown('<h2>Heading</h2> after'),
        'Heading after',
      );
      expect(normalizeHtmlishMarkdown('<h3>a<code>b</code>c</h3>'), 'a`b`c');
      expect(normalizeHtmlishMarkdown('<h2>Heading'), '<h2>Heading');
      // `<h4>` implies the close of `<h3>`, so the open tag is left dangling.
      expect(normalizeHtmlishMarkdown('<h3>a</h4>'), '<h3>a');
    });

    test('code becomes a backtick span only when its body is pure text', () {
      expect(normalizeHtmlishMarkdown('<code></code>'), '``');
      expect(
        normalizeHtmlishMarkdown('<code>a</code><code>b</code>'),
        '`a``b`',
      );
      expect(normalizeHtmlishMarkdown('<code>`</code>'), '```');
      expect(
        normalizeHtmlishMarkdown('<code>a<b>c</b></code>'),
        '<code>a<b>c</b></code>',
      );
      expect(normalizeHtmlishMarkdown('<code><br></code>'), '<code>\n</code>');
    });

    test('an image inside an unwrapped element still splits out', () {
      expect(
        splitHtmlishMarkdown('<sub><img src="https://a/b.png" alt="A"></sub>'),
        [
          const MarkdownTextPart('<sub>'),
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
        ],
      );
      expect(
        splitHtmlishMarkdown('<h3><img src="https://a/b.png" alt="A"></h3>'),
        [
          const MarkdownTextPart('<h3>'),
          const MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
        ],
      );
    });

    test('unknown balanced tags round-trip verbatim', () {
      for (final source in const [
        '<unknown attr>body</unknown>',
        '<em>a</em><strong>b</strong>',
        '<span data-a>x</span>',
        '<blockquote><p>hi</p></blockquote>',
        '<table><tr><td>a</td></tr></table>',
      ]) {
        expect(normalizeHtmlishMarkdown(source), source, reason: source);
      }
    });

    test('implied closes leave the reconstructed source unchanged', () {
      for (final source in const [
        '<p>one<p>two',
        '<td>a<td>b',
        '<li>a<li>b',
        '<ul><li>a<li>b</ul>',
        '<select><option>a<option>b</select>',
        '<dl><dt>a<dd>b</dl>',
      ]) {
        expect(normalizeHtmlishMarkdown(source), source, reason: source);
      }
    });

    test('a second form element is dropped entirely', () {
      expect(
        normalizeHtmlishMarkdown('<form><form>a</form></form>'),
        '<form>a</form>',
      );
    });

    test('a self-closing unknown tag re-renders without the slash', () {
      expect(normalizeHtmlishMarkdown('<div/>'), '<div>');
    });

    test('attribute values are re-escaped when a tag is re-rendered', () {
      expect(
        normalizeHtmlishMarkdown(
          '<span data-x="1&2" title=\'He said "hi"\'>t</span>',
        ),
        '<span data-x="1&amp;2" title="He said &quot;hi&quot;">t</span>',
      );
    });

    test('the first of a repeated attribute wins', () {
      expect(
        splitHtmlishMarkdown(
          '<img SRC="https://a/b.png" SRC="https://c/d.png" alt="dup">',
        ),
        [const MarkdownInlineImagePart(alt: 'dup', src: 'https://a/b.png')],
      );
    });

    test('value-less attributes are accepted in either order', () {
      expect(splitHtmlishMarkdown('<img src="https://a/b.png" alt>'), [
        const MarkdownInlineImagePart(alt: '', src: 'https://a/b.png'),
      ]);
      expect(splitHtmlishMarkdown('<img alt src="https://a/b.png">'), [
        const MarkdownInlineImagePart(alt: '', src: 'https://a/b.png'),
      ]);
    });

    test('whitespace and missing separators inside tags are tolerated', () {
      const expected = [
        MarkdownInlineImagePart(alt: 'A', src: 'https://a/b.png'),
      ];
      expect(
        splitHtmlishMarkdown('<img src = "https://a/b.png" alt = "A">'),
        expected,
      );
      expect(
        splitHtmlishMarkdown('<img src="https://a/b.png"alt="A">'),
        expected,
      );
      expect(
        splitHtmlishMarkdown('<img src="https://a/b.png" alt="A"/>'),
        expected,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Extra coverage: tokenizer behaviour on hostile or unusual markup
  // -------------------------------------------------------------------------
  group('tokenizer edges', () {
    test('a bare angle bracket is text, not a tag', () {
      expect(normalizeHtmlishMarkdown('a < b and c > d'), 'a < b and c > d');
      expect(normalizeHtmlishMarkdown('a <3 b'), 'a <3 b');
      expect(
        normalizeHtmlishMarkdown('< img src="https://a/b.png">'),
        '< img src="https://a/b.png">',
      );
      expect(
        normalizeHtmlishMarkdown('<0img src="https://a/b.png">'),
        '<0img src="https://a/b.png">',
      );
    });

    test('an unterminated tag is dropped rather than emitted as text', () {
      expect(
        splitHtmlishMarkdown('<img src="https://a/b.png" alt="A"'),
        isEmpty,
      );
      expect(
        splitHtmlishMarkdown('<img src="https://a/b.png" alt="unterminated'),
        isEmpty,
      );
    });

    test('raw-text elements keep their bodies literal', () {
      for (final source in const [
        '<style>a{color:red}</style>Body',
        '<script>if (a<b) {}</script>Tail',
        '<title>Hi</title>Tail',
        '<textarea>a<b</textarea>Tail',
        '<xmp>a<b></xmp>d',
        '<noembed>x</noembed>after',
        '<noframes>x</noframes>after',
        '<iframe>x</iframe>after',
      ]) {
        expect(normalizeHtmlishMarkdown(source), source, reason: source);
      }
    });

    test('plaintext swallows the rest of the source', () {
      expect(normalizeHtmlishMarkdown('<plaintext>a<b>c'), '<plaintext>a<b>c');
    });

    test('raw-text detection is case-insensitive', () {
      expect(
        normalizeHtmlishMarkdown('<IFRAME>x</IFRAME>after'),
        '<iframe>x</iframe>after',
      );
    });

    test('tags that merely share a prefix with raw-text tags are ordinary', () {
      for (final source in const ['<scr>x</scr>', '<st>x</st>', '<t>x</t>']) {
        expect(normalizeHtmlishMarkdown(source), source, reason: source);
      }
    });

    test('a self-closing script or style erases itself, others do not', () {
      expect(normalizeHtmlishMarkdown('<script src="x"/>after'), 'after');
      expect(normalizeHtmlishMarkdown('<style/>after'), 'after');
      expect(normalizeHtmlishMarkdown('<title/>after'), '<title>after');
      expect(normalizeHtmlishMarkdown('<textarea/>after'), '<textarea>after');
    });

    test('the image element is aliased to img outside foreign content', () {
      expect(
        splitHtmlishMarkdown(
          '<image src="https://example.com/a.png" alt="Aliased">',
        ),
        [
          const MarkdownInlineImagePart(
            alt: 'Aliased',
            src: 'https://example.com/a.png',
          ),
        ],
      );
    });

    test('inside svg the image element keeps its own name', () {
      expect(
        normalizeHtmlishMarkdown('<svg><image href="x"/></svg>'),
        '<svg><image href="x"></svg>',
      );
    });

    test('svg element names keep their mixed case', () {
      expect(
        normalizeHtmlishMarkdown(
          '<svg><foreignObject><div>x</div></foreignObject></svg>',
        ),
        '<svg><foreignObject><div>x</div></foreignObject></svg>',
      );
      expect(
        normalizeHtmlishMarkdown('<svg><clipPath/></svg>'),
        '<svg><clipPath></svg>',
      );
    });

    test('math and integration-point elements round-trip', () {
      expect(
        normalizeHtmlishMarkdown('<math><mi>x</mi></math>'),
        '<math><mi>x</mi></math>',
      );
      expect(
        normalizeHtmlishMarkdown('<annotation-xml>x</annotation-xml>'),
        '<annotation-xml>x</annotation-xml>',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Extra coverage: comments, declarations and CDATA
  // -------------------------------------------------------------------------
  group('comments, declarations and CDATA', () {
    test('a comment that starts a line swallows the newline after it', () {
      expect(
        normalizeHtmlishMarkdown('<!-- marker -->\nAfter comment'),
        'After comment',
      );
      expect(normalizeHtmlishMarkdown('a\n<!-- c -->\nb'), 'a\nb');
      expect(normalizeHtmlishMarkdown('a\r\n<!-- c -->\r\nb'), 'a\r\nb');
    });

    test('a mid-line comment leaves the following newline alone', () {
      expect(
        normalizeHtmlishMarkdown('text <!-- marker -->\nAfter comment'),
        'text \nAfter comment',
      );
    });

    test(
      'only a line-leading comment strips, so a second one on the line does not',
      () {
        expect(normalizeHtmlishMarkdown('<!-- a --><!-- b -->\nx'), '\nx');
      },
    );

    test('a comment with no newline after it strips nothing', () {
      expect(normalizeHtmlishMarkdown('<!-- c -->x'), 'x');
    });

    test('abrupt and over-long comment terminators are still comments', () {
      for (final source in const [
        '<!-->x',
        '<!--->x',
        '<!--- long ---->x',
        '<!--a--b-->x',
        '<!--a--->x',
        '<!--a---->x',
      ]) {
        expect(normalizeHtmlishMarkdown(source), 'x', reason: source);
      }
    });

    test('a multi-line comment strips only the newline after it', () {
      expect(normalizeHtmlishMarkdown('<!--\n-->\nx'), 'x');
    });

    test('an unterminated comment consumes the rest of the source', () {
      expect(splitHtmlishMarkdown('<!-- unterminated'), isEmpty);
    });

    test('doctypes and bogus declarations disappear', () {
      expect(normalizeHtmlishMarkdown('<!DOCTYPE html>\nHello'), '\nHello');
      expect(normalizeHtmlishMarkdown('<! bogus >x'), 'x');
      expect(normalizeHtmlishMarkdown('<!x>y'), 'y');
      expect(normalizeHtmlishMarkdown('<!DOCTYPE>y'), 'y');
      expect(normalizeHtmlishMarkdown('<!doctypex>y'), 'y');
    });

    test('a processing instruction is a bogus comment in HTML mode', () {
      expect(normalizeHtmlishMarkdown('<?php echo 1; ?>tail'), 'tail');
    });

    test('malformed closing tags are bogus comments', () {
      expect(normalizeHtmlishMarkdown('</ >tail'), 'tail');
      expect(normalizeHtmlishMarkdown('</3>tail'), 'tail');
    });

    test('CDATA outside foreign content is a comment and vanishes', () {
      expect(normalizeHtmlishMarkdown('<![CDATA[secret]]>after'), 'after');
      expect(normalizeHtmlishMarkdown('<![CDATA[a]]]>b'), 'b');
      expect(splitHtmlishMarkdown('<![CDATA[unterminated'), isEmpty);
    });

    test('CDATA inside svg is text', () {
      expect(
        normalizeHtmlishMarkdown('<svg><![CDATA[raw]]></svg>'),
        '<svg>raw</svg>',
      );
    });

    test(
      'a comment inside a details body disappears with the newline rules intact',
      () {
        expect(
          splitHtmlishMarkdown(
            '<details><summary>S</summary><!-- x -->body</details>',
          ),
          [const MarkdownDetailsPart(summary: 'S', body: 'body')],
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Extra coverage: degenerate inputs
  // -------------------------------------------------------------------------
  group('degenerate inputs', () {
    test('an empty source produces no parts', () {
      expect(splitHtmlishMarkdown(''), isEmpty);
      expect(normalizeHtmlishMarkdown(''), '');
    });

    test('whitespace-only sources are preserved exactly', () {
      expect(splitHtmlishMarkdown('   '), [const MarkdownTextPart('   ')]);
      expect(splitHtmlishMarkdown('\n\n'), [const MarkdownTextPart('\n\n')]);
    });

    test('adjacent markdown runs are always merged into one part', () {
      // Comments and stray closing tags produce nothing, so the text on either
      // side has to fuse rather than become two neighbouring parts.
      final parts = splitHtmlishMarkdown('one<!-- c -->two</p>three');
      expect(parts, [const MarkdownTextPart('onetwothree')]);
    });

    test('normalize and split agree on plain markdown', () {
      const source =
          'A paragraph with `code`, **bold** and a [link](https://x).';
      expect(normalizeHtmlishMarkdown(source), source);
      expect(splitHtmlishMarkdown(source), [const MarkdownTextPart(source)]);
    });
  });
}
