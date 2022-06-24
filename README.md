# A collection of work on COIBot

## Database
The hardcoded database is called `coibot`, with the username also set to `coibot`
### Tables
#### trusted_users
 - `cloak`
#### blacklist
 - `username`
 - `string` (?)
 - `reason`
#### whitelist
 - `username`
 - `string` (?)
 - `reason`
#### monitor
 - ?
#### report
 - `username`
 - `language`
 - `page`
 - `url`
 - `fullurl`
 - `diff`
 - `time`

## Perl version
The version in the perl subdirectory was initally taken from [meta.wikimedia](https://meta.wikimedia.org/wiki/Special:Permalink/15888583) — the licence is assumed to be [Creative Commons Attribution-ShareAlike](https://creativecommons.org/licenses/by-sa/3.0/) as it was posted on-wiki.

### Issues
- [ ] **I don't know Perl**
- [ ] `Wikimedia` perl module does not exist
- [ ] `Wikipedia` perl module does not exist
- [ ] `perlwikipedia` perl module does not exist
  - [ ] The above 3 modules might be replaced by `MediaWiki::Bot` and `WWW::Wikipedia`

### Config files
- COIBot-mw-password
- COIBot-wp-password
- coibot-password
- COIBot-db-password

## Python version
This is an attempt at a rewrite of the core functionality.