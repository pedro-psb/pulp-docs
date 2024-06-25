FROM ubuntu:latest

RUN apt-get -y update
RUN apt-get -y upgrade
RUN apt-get install -y libgirepository1.0-dev gcc libcairo2-dev pkg-config python3-dev gir1.2-gtk-4.0

WORKDIR app

COPY . .

CMD ["alias", "python=python3"] 
CMD ["./update-data.sh", "/tmp", "-l", "pulp_ostree"] 
