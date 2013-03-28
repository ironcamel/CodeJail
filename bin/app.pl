#!/usr/bin/env perl
use Dancer;
use Dancer::Plugin::Stomp qw(stomp_send);

post '/' => sub {
    stomp_send { destination => config->{queue}, body => request->body };
    status 202;
};

dance;
