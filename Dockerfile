FROM ruby:latest as build

WORKDIR /logstash-input-airthings
COPY [".", "."]
RUN gem build *.gemspec

FROM docker.elastic.co/logstash/logstash:8.2.2

COPY --from=build ["/logstash-input-airthings/logstash-input-airthings-0.1.0.gem", "."]

RUN bin/logstash-plugin install logstash-input-airthings-0.1.0.gem

ENTRYPOINT ["logstash"]
