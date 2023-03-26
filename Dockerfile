FROM node:15-alpine

COPY . /src
RUN npm install @azure/storage-blob
RUN cd /src && npm install
EXPOSE 80
CMD ["node", "/src/server.js"]
