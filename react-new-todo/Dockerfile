# pull official base image
FROM public.ecr.aws/docker/library/node:16.18.1-alpine

# set working directory
WORKDIR /react-new-todo

# add `/react-new-todo/node_modules/.bin` to $PATH
ENV PATH /react-new-todo/node_modules/.bin:$PATH

# install app dependencies
COPY package.json ./
COPY package-lock.json ./
RUN npm install --silent
RUN npm install react-scripts@3.4.1 -g --silent

# add app
COPY . ./

# Make port 3000 available to the world outside this container
EXPOSE 3000

# start app
CMD ["npm", "start"]