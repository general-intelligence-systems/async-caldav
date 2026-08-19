FROM ruby:3.4

WORKDIR /app

COPY async-caldav.gemspec Gemfile ./
COPY lib/ lib/

COPY examples/docker/Gemfile examples/docker/Gemfile
RUN cd examples/docker && rm -f Gemfile.lock && bundle install --jobs 4

COPY . .
RUN cd examples/docker && bundle install --jobs 4

EXPOSE 9292

WORKDIR /app/examples/docker

CMD ["bundle", "exec", "falcon", "host"]
