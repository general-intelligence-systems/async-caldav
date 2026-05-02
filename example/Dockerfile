FROM ruby:3.4

WORKDIR /app

# Copy both gems
COPY protocol-caldav/protocol-caldav.gemspec protocol-caldav/protocol-caldav.gemspec
COPY protocol-caldav/lib/ protocol-caldav/lib/

COPY async-caldav/async-caldav.gemspec async-caldav/async-caldav.gemspec
COPY async-caldav/lib/ async-caldav/lib/

COPY async-caldav/example/Gemfile async-caldav/example/Gemfile
RUN cd async-caldav/example && rm -f Gemfile.lock && bundle install --jobs 4

COPY async-caldav/ async-caldav/
COPY protocol-caldav/ protocol-caldav/

RUN cd async-caldav/example && bundle install --jobs 4

EXPOSE 9292

WORKDIR /app/async-caldav/example

CMD ["bundle", "exec", "falcon", "host"]
