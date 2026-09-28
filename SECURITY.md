# Security policy

Pear'd handles sign-in, invite codes and the photos people send each other, so
a vulnerability report is welcome and taken seriously.

## Reporting a vulnerability

Please report it privately, not in a public issue, pull request or discussion.

1. **GitHub's private reporting.** Open the repository's **Security** tab and
   choose **Report a vulnerability**, or go straight to
   <https://github.com/KRoperUK/peard/security/advisories/new>. Only the
   maintainer can see the report, and a fix can be prepared in a private fork
   before anything is published.
2. **Email**, if you would rather not use GitHub, or the button is missing:
   <kieran@kroper.uk>. This is the same address as the privacy policy's.

A useful report says what is affected (the app, the server, the website or the
deployment), how to reproduce it, and what somebody could do with it. A proof
of concept helps, but please test only against your own account and data,
never another person's.

This is a one-person project, so there is no bounty and no formal SLA. Expect
an acknowledgement within a few days. You will be told when a fix ships, and
credited in the advisory unless you would rather not be.

## Supported versions

Fixes go to the newest code only.

| What | Supported |
|---|---|
| `main`, and the server deployed from it | yes |
| The latest TestFlight build | yes |
| Any earlier TestFlight build | no, so update to the latest |

There is no App Store release yet. When there is, this table will say which
versions receive fixes.
