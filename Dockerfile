FROM node:15-alpine

COPY . /src
WORKDIR /src
RUN rm -rf node_modules package-lock.json && \
    npm install -g npm@latest && \
    npm install @azure/storage-blob && \
    npm install
EXPOSE 80
CMD ["node", "/src/server.js"]
