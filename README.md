# Description

CodeJail is a scalable and generic sandboxing system for securely running
code in any language.
The code behavior can be verified and the results reported via a callback url.

# Prerequisites

In order to install the dependencies, you will need cpanminus.
This package is provided by most modern linux distros.
For example, you can install it on Debian/Ubuntu based systems via:

    apt-get install cpanminus

Or you can install it manually by running:

    curl -L http://cpanmin.us | perl - --sudo App::cpanminus

# Installation

First, download the source code and cd to the project folder:

    git clone git://github.com/ironcamel/CodeJail.git
    cd CodeJail

Install the dependencies:

    sudo cpanm --installdeps .

Install the Message Queue. This can be installed on a remote server or the
same server as the CodeJail worker.

    sudo cpanm POE::Component::MessageQueue

# Configuration

    cp config.example.yml config.yml

Edit the `config.yml` file accordingly.

# Usage

Start the message queue:

    sudo mq.pl

Start the codejail worker:

    sudo ./bin/codejail.pl
