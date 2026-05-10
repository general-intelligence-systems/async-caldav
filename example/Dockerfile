FROM ruby:3.4

WORKDIR /app

COPY async-caldav.gemspec Gemfile ./
COPY lib/ lib/

COPY example/Gemfile example/Gemfile
RUN cd example && rm -f Gemfile.lock && bundle install --jobs 4

COPY . .
RUN cd example && bundle install --jobs 4

EXPOSE 9292

WORKDIR /app/example

CMD ["bundle", "exec", "falcon", "host"]
