# frozen_string_literal: true

source "https://rubygems.org"

# Spelled out rather than pulled in through `gemspec`: bundlerEnv copies only
# the Gemfile and the lockfile into the store, so the .gemspec that directive
# would read is not there to read. async-caldav.gemspec stays the manifest for
# the released gem; this file is what the devshell resolves.
gem "protocol-caldav", "~> 1.1"

group :development do
  gem "rubocop", "~> 1.0"
  gem "scampi", "~> 1.0"
end
